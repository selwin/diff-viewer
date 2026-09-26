import AppKit
import Foundation
import Testing

@testable import DiffViewer

/// Stage-by-stage timings for one Swift file of 2,000 and 5,000 lines: the load pipeline
/// (difft, alignment, tree-sitter highlighting) and the pane renderer (install, shaping,
/// drawing while scrolling). Opt-in, because timings are meaningless in a Debug build and
/// slow the suite down: run with `DIFFVIEWER_BENCHMARKS=1` (through xcodebuild,
/// `TEST_RUNNER_DIFFVIEWER_BENCHMARKS=1`). The report is printed and written to
/// `DIFFVIEWER_BENCHMARK_REPORT`, default `/tmp/diffviewer-benchmark.md`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DIFFVIEWER_BENCHMARKS"] == "1"), .serialized)
struct RenderPerfBenchmarks {
    static let sizes = [2000, 5000]
    static let repetitions = 5
    static let fileName = "Benchmark.swift"

    @Test func stageBreakdown() async throws {
        var report = Report()
        report.line("# DiffViewer benchmark")
        report.line("")
        let info = ProcessInfo.processInfo
        report.line("Host: \(sysctlString("machdep.cpu.brand_string")) (\(sysctlString("hw.model"))), ")
        report.line("\(info.activeProcessorCount) cores, \(info.physicalMemory >> 30) GB, ")
        report.line("macOS \(info.operatingSystemVersionString). Times in ms; medians of ")
        report.line("\(Self.repetitions) runs unless noted. Input: the app's own Swift sources, cut to N lines, ")
        report.line("with 10 scattered hunks (2 lines edited, 4 inserted, 2 deleted each) on the new side.")
        report.line("")

        // Before anything else touches the grammar, so this is the cold load.
        let coldStart = PerfProbe.now()
        _ = LanguageRegistry.configuration(forFileNamed: Self.fileName)
        report.line("Cold Swift grammar + highlight query load (first file of a session): \(ms(since: coldStart))")
        report.line("")

        let corpus = Self.corpus()
        #expect(corpus.count >= Self.sizes.max()!, "not enough source lines for the corpus")
        for size in Self.sizes {
            let (old, new) = Self.texts(corpus: corpus, lineCount: size)
            report.line("## \(size) lines")
            report.line("")
            let output = try await loadPipeline(old: old, new: new, report: &report)
            guard case let .text(document) = output.content else {
                Issue.record("expected a text document")
                continue
            }
            renderPipeline(document: document, styles: output.styles, report: &report)
        }

        let text = report.text
        print(text)
        let path = ProcessInfo.processInfo.environment["DIFFVIEWER_BENCHMARK_REPORT"] ?? "/tmp/diffviewer-benchmark.md"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Load

    /// difft on its own, then `DiffEngine.build` end to end with fresh caches, then the
    /// highlighter on its own with the probes off to show their overhead.
    private func loadPipeline(old: String, new: String, report: inout Report) async throws -> DiffEngine.Output {
        let sources = DiffEngine.Sources(old: Data(old.utf8), new: Data(new.utf8), fileName: Self.fileName)

        var difftTimes: [Double] = []
        for _ in 0..<3 {
            let start = PerfProbe.now()
            _ = try await DifftRunner.run(old: sources.old, new: sources.new, fileName: Self.fileName)
            difftTimes.append(msValue(since: start))
        }

        var runs: [[String: PerfProbe.Stat]] = []
        var totals: [Double] = []
        var output: DiffEngine.Output?
        for _ in 0..<Self.repetitions {
            PerfProbe.startRecording()
            let start = PerfProbe.now()
            output = try await DiffEngine.build(
                sources, hideWhitespace: false, cache: DifftCache.bundled(), resultCache: DiffResultCache(),
                priority: .foreground)
            totals.append(msValue(since: start))
            runs.append(PerfProbe.stopRecording())
        }

        let oldLines = TextLines.split(old)
        var plain: [Double] = []
        for _ in 0..<Self.repetitions {
            let start = PerfProbe.now()
            _ = Highlighter.highlight(lines: oldLines, fileName: Self.fileName)
            plain.append(msValue(since: start))
        }

        report.line("### Load (background, per file open)")
        report.line("")
        report.line("| Stage | ms | Notes |")
        report.line("|---|---:|---|")
        report.row("difft alone (process, parse, JSON)", median(difftTimes), "median of 3")
        report.row("**DiffEngine.build total**", median(totals), "fresh caches, includes difft")
        for (stage, note) in [
            ("engine.decode", "UTF-8 → String, both sides"),
            ("engine.difft", "via DifftCache"),
            ("engine.split", "both sides"),
            ("engine.align", "Myers + difft hints"),
            ("engine.highlightOld", "old side, sequential"),
            ("engine.highlightNew", "new side"),
        ] {
            report.row("  \(stage)", median(runs.map { $0[stage]?.milliseconds ?? 0 }), note)
        }
        report.line("")
        report.line("Highlighter stages, summed over both sides:")
        report.line("")
        report.line("| Stage | ms | Count |")
        report.line("|---|---:|---:|")
        for stage in [
            "highlight.total", "highlight.config", "highlight.join", "highlight.parse", "highlight.query",
            "highlight.query.nextMatch", "highlight.query.predicates", "highlight.query.captureMapping",
            "highlight.sort", "highlight.paint", "highlight.runs",
        ] {
            let stat = runs.map { $0[stage] ?? PerfProbe.Stat() }
            report.row(stage, median(stat.map(\.milliseconds)), "\(stat.first?.count ?? 0)")
        }
        let painted = runs.first?["highlight.paintedCaptures"]?.count ?? 0
        report.line("")
        report.line("Painted captures (both sides): \(painted). ")
        report.line("Highlighter on the old side with probes off: \(format(median(plain))) ms.")
        report.line("")
        return try #require(output)
    }

    // MARK: - Render

    private func renderPipeline(document: DiffDocument, styles: SyntaxStyles?, report: inout Report) {
        report.line("### Render (main thread)")
        report.line("")
        for collapse in [false, true] {
            let harness = PaneHarness()
            harness.container.setCollapseUnchanged(collapse)

            PerfProbe.startRecording()
            let installStart = PerfProbe.now()
            harness.container.setContent(.file(document), fontSize: 12)
            harness.container.layoutSubtreeIfNeeded()
            let install = msValue(since: installStart)
            PerfProbe.stopRecording()

            // The document is shown before its styles arrive, as in the app.
            let firstPaint = harness.drawFrame()
            PerfProbe.startRecording()
            let stylesStart = PerfProbe.now()
            harness.container.setStyles(
                DocumentStyles(documentID: document.id, revision: 0, old: styles?.old, new: styles?.new))
            _ = harness.drawFrame()
            let stylesArrive = msValue(since: stylesStart)
            PerfProbe.stopRecording()

            let mode = collapse ? "collapse unchanged ON (default)" : "collapse unchanged OFF (whole file)"
            report.line("#### \(mode): \(harness.container.folded.displayRows.count) display rows")
            report.line("")
            report.line("Install (setContent + layout): \(format(install)) ms. ")
            report.line("First frame, no styles, cold cache: \(format(firstPaint)) ms. ")
            report.line("Styles arrive → cache wiped → redraw visible rows: \(format(stylesArrive)) ms.")
            report.line("")
            report.line(
                "| Scroll pass | Frames | Total ms | Median frame | p95 frame | Max frame | Shaped | Evict-all |")
            report.line("|---|---:|---:|---:|---:|---:|---:|---:|")
            var paneStats: [String: PerfProbe.Stat] = [:]
            for (label, step) in [("page jumps, cold", 0), ("page jumps, warm", 0), ("trackpad 40pt, warm", 40)] {
                PerfProbe.startRecording()
                let frames = harness.scrollThrough(step: step == 0 ? nil : CGFloat(step))
                let stats = PerfProbe.stopRecording()
                if label == "page jumps, cold" { paneStats = stats }
                report.line(
                    "| \(label) | \(frames.count) | \(format(frames.reduce(0, +))) | \(format(median(frames))) | "
                        + "\(format(percentile(frames, 0.95))) | \(format(frames.max() ?? 0)) | "
                        + "\(stats["pane.shape"]?.count ?? 0) | \(stats["pane.lineCache.evictAll"]?.count ?? 0) |")
            }
            report.line("")
            report.paneBreakdown(paneStats)
        }
    }

    // MARK: - Input

    /// Every Swift source line of the app, in a stable order.
    static func corpus() -> [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DiffViewer", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        return files.flatMap { TextLines.split((try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
    }

    /// The first `lineCount` corpus lines, and a copy with 10 evenly spaced hunks.
    static func texts(corpus: [String], lineCount: Int) -> (old: String, new: String) {
        let old = Array(corpus.prefix(lineCount))
        var new: [String] = []
        let spacing = lineCount / 11
        var index = 0
        while index < old.count {
            let hunk = index / spacing
            if index % spacing == 0, index > 0, hunk <= 10 {
                new.append(old[index] + " // reviewed")
                new.append(old[index + 1] + " // reviewed")
                new.append(contentsOf: (0..<4).map { "        let benchmarkValue\(hunk)_\($0) = \($0) * 2" })
                // Skips the two edited lines and deletes the two after them.
                index += 4
                continue
            }
            new.append(old[index])
            index += 1
        }
        return (old.joined(separator: "\n") + "\n", new.joined(separator: "\n") + "\n")
    }
}

/// A side-by-side container in an offscreen window, drawn the way AppKit draws it.
@MainActor
private final class PaneHarness {
    let window: NSWindow
    let container = SideBySideContainerView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
    }

    private var scrollView: NSScrollView { container.rightPane.enclosingScrollView! }

    /// Draws the visible part of both panes; returns milliseconds spent drawing, not
    /// counting the bitmap allocation.
    func drawFrame(strip: CGFloat? = nil) -> Double {
        var elapsed = 0.0
        for pane in [container.leftPane, container.rightPane] {
            var rect = pane.visibleRect
            if let strip { rect = NSRect(x: rect.minX, y: rect.maxY - strip, width: rect.width, height: strip) }
            guard !rect.isEmpty, let rep = pane.bitmapImageRepForCachingDisplay(in: rect) else { continue }
            let start = PerfProbe.now()
            pane.cacheDisplay(in: rect, to: rep)
            elapsed += msValue(since: start)
        }
        return elapsed
    }

    /// Scrolls from the top to the bottom, a viewport at a time (`step` nil, every frame
    /// redraws the whole viewport) or `step` points at a time (only the exposed strip is
    /// drawn, as a layer-backed clip view does). Returns each frame's milliseconds.
    func scrollThrough(step: CGFloat?) -> [Double] {
        let clip = scrollView.contentView
        let viewport = clip.bounds.height
        let maxY = max(0, container.rightPane.frame.height - viewport)
        scroll(to: 0)
        var frames: [Double] = []
        var y: CGFloat = 0
        while y < maxY {
            y = min(maxY, y + (step ?? viewport))
            scroll(to: y)
            frames.append(drawFrame(strip: step))
        }
        return frames
    }

    private func scroll(to y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

private struct Report {
    private(set) var text = ""

    mutating func line(_ string: String) { text += string + "\n" }

    mutating func row(_ label: String, _ value: Double, _ note: String) {
        line("| \(label) | \(format(value)) | \(note) |")
    }

    /// Where the main-thread time went during the cold scroll pass.
    mutating func paneBreakdown(_ stats: [String: PerfProbe.Stat]) {
        line("Cold page-jump pass, main-thread time by stage (both panes):")
        line("")
        line("| Stage | Total ms | Count | µs each |")
        line("|---|---:|---:|---:|")
        for stage in [
            "pane.draw", "pane.row.background", "pane.row.cachedLine", "pane.shape", "pane.shape.tabExpand",
            "pane.shape.attributes", "pane.shape.ctLineCreate", "pane.shape.typographicBounds",
            "pane.row.tokenHighlights", "pane.row.drawText", "pane.row.pad", "pane.row.gutter",
        ] {
            let stat = stats[stage] ?? PerfProbe.Stat()
            let each = stat.count > 0 ? stat.milliseconds * 1000 / Double(stat.count) : 0
            line("| \(stage) | \(format(stat.milliseconds)) | \(stat.count) | \(format(each)) |")
        }
        let hits = stats["pane.lineCache.hit"]?.count ?? 0
        line("")
        line("Line cache hits: \(hits). Rows drawn: \(stats["pane.draw.rows"]?.count ?? 0).")
        line("")
    }
}

private func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buffer)
}

private func msValue(since start: UInt64) -> Double { Double(PerfProbe.now() - start) / 1_000_000 }
private func ms(since start: UInt64) -> String { format(msValue(since: start)) + " ms" }
private func format(_ value: Double) -> String { String(format: value < 10 ? "%.2f" : "%.1f", value) }

private func median(_ values: [Double]) -> Double { percentile(values, 0.5) }

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}
