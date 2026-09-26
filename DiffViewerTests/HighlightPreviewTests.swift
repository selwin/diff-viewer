import Foundation
import Testing

@testable import DiffViewer

/// A cache whose difft always fails, so every file falls back to the plain line diff.
private func plainDifftCache() -> DifftCache {
    DifftCache(runner: { _, _, _, _ in throw ProcessError.failed(command: "difft", status: 1, stderr: "no difft") })
}

/// `count` lines of Swift, each ending with `suffix` so two versions differ on every line.
private func swiftSource(lines count: Int, suffix: String) -> Data {
    Data((0..<count).map { "let v\($0) = \($0) // \(suffix)\n" }.joined().utf8)
}

/// Records, in order, how many lines each highlight call got and when the preview arrived.
private actor PassLog {
    enum Event: Equatable {
        case highlight(lines: Int)
        case preview(old: Int?, new: Int?)
    }

    private(set) var events: [Event] = []
    private(set) var previewDocumentID: UUID?

    func record(_ event: Event) { events.append(event) }

    func recordPreview(_ document: DiffDocument, _ styles: SyntaxStyles) {
        previewDocumentID = document.id
        events.append(.preview(old: styles.old?.count, new: styles.new?.count))
    }

    /// Colours one run per line, like `HighlighterProbe`.
    nonisolated func highlight() -> DiffEngine.Highlight {
        { [self] lines, _ in
            await record(.highlight(lines: lines.count))
            return lines.map { _ in [StyleRun(range: 0..<1, style: .keyword)] }
        }
    }

    nonisolated func preview() -> DiffEngine.Preview {
        { [self] document, styles in await recordPreview(document, styles) }
    }
}

struct HighlightPreviewTests {
    private func build(oldLines: Int, newLines: Int, log: PassLog) async throws -> DiffEngine.Output {
        let sources = DiffEngine.Sources(
            old: swiftSource(lines: oldLines, suffix: "old"), new: swiftSource(lines: newLines, suffix: "new"),
            fileName: "a.swift")
        return try await DiffEngine.build(
            sources, hideWhitespace: false, cache: plainDifftCache(), resultCache: DiffResultCache(),
            priority: .foreground, highlight: log.highlight(), preview: log.preview())
    }

    /// A long file is coloured in two passes: the first 200 lines of each side, handed to
    /// the preview, then every line.
    @Test func aLongFileGetsAPreviewOfItsFirstLinesBeforeTheFullPass() async throws {
        let log = PassLog()
        let output = try await build(oldLines: 250, newLines: 300, log: log)

        let events = await log.events
        #expect(
            events == [
                .highlight(lines: 200),
                .highlight(lines: 200),
                .preview(old: 200, new: 200),
                .highlight(lines: 250),
                .highlight(lines: 300),
            ])
        guard case let .text(document) = output.content else {
            Issue.record("text expected")
            return
        }
        #expect(await log.previewDocumentID == document.id, "the preview colours the final document")
        #expect(output.styles?.old?.count == 250)
        #expect(output.styles?.new?.count == 300)
    }

    /// One long side is enough for a preview; the short side is coloured whole in it.
    @Test func oneLongSideIsEnoughForAPreview() async throws {
        let log = PassLog()
        _ = try await build(oldLines: 20, newLines: 201, log: log)
        #expect(await log.events.contains(.preview(old: 20, new: 200)))
    }

    /// A file whose sides both fit in the preview gets a single pass.
    @Test func aShortFileHasNoPreview() async throws {
        let log = PassLog()
        _ = try await build(oldLines: 200, newLines: 150, log: log)
        #expect(await log.events == [.highlight(lines: 200), .highlight(lines: 150)])
    }
}

@MainActor
struct DiffLoaderPreviewTests {
    /// The preview's styles only cover the first lines, so the loader must finish on the
    /// full snapshot for the same document.
    @Test func aLongFileEndsWithItsFullStyles() async {
        let client = StubRepoClient(files: [])
        await client.set(index: swiftSource(lines: 300, suffix: "old"), for: "a.swift")
        await client.set(worktree: swiftSource(lines: 300, suffix: "new"), for: "a.swift")
        let loader = DiffLoader(cache: plainDifftCache())

        loader.load(file: changedFile("a.swift"), client: client, hideWhitespace: true)
        #expect(await eventually { await !loader.hasActiveWork })
        guard case let .text(document)? = loader.content else {
            Issue.record("text expected")
            return
        }
        #expect(loader.styles?.documentID == document.id)
        #expect(loader.styles?.isPreview == false)
        #expect(loader.styles?.new?.count == 300)
    }
}
