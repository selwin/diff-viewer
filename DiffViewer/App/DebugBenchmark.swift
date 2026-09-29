import AppKit
import Foundation

#if DEBUG
    /// Debug-only pipeline benchmark, run by `DIFFVIEWER_BENCH=<workload>` on the first
    /// populated window. Each workload prints `bench ...` lines to stdout, then quits:
    /// - `single:<file id>`: cold load of one file, selection to content.
    /// - `all`: cold All changes, selection to first and last publication.
    /// - `edit:<file id>:<saves>`: per save, appends a line to the file and runs the
    ///   watcher's refresh directly (the watcher ignores the app's own writes), timing it
    ///   to the new content, with process, prefetch and parse counts once all work is idle.
    ///   A script-launched window is never key, so prefetch is started here the way the
    ///   coordinator starts it for the key window.
    /// - `sustain:<seconds>`: a child process appends to `bench-sustain.txt` every 100 ms
    ///   while a separate `RepoWatcher` on the repository reports when it fires.
    ///
    /// Panes are displayed every 16 ms while waiting, as the display cycle would, because
    /// a script-launched window is occluded and would otherwise not draw.
    @MainActor
    enum DebugBenchmark {
        private static var started = false

        /// Runs the workload in `DIFFVIEWER_BENCH`, once per launch, after restoration.
        static func start(services: AppServices) {
            guard !started, let workload = ProcessInfo.processInfo.environment["DIFFVIEWER_BENCH"], !workload.isEmpty
            else { return }
            started = true
            Task {
                _ = await wait(timeout: .seconds(30)) { services.coordinator.phase == .running }
                await run(workload, services: services)
            }
        }

        private static func run(_ workload: String, services: AppServices) async {
            // File ids contain colons, so only the kind and a trailing count are split off.
            let kind = workload.prefix { $0 != ":" }
            let argument = String(workload.dropFirst(kind.count + 1))
            let editFile = argument.split(separator: ":").dropLast().joined(separator: ":")
            let editSaves = Int(argument.split(separator: ":").last ?? "") ?? 5
            let coordinator = services.coordinator
            let ready = await wait(timeout: .seconds(30)) {
                coordinator.windows.values.contains { !$0.files.isEmpty }
            }
            guard ready, let state = coordinator.windows.values.first(where: { !$0.files.isEmpty }) else {
                report("error no populated window")
                return quit()
            }
            let window = services.windows[state.id]
            switch kind {
            case "single":
                await single(argument, state: state, window: window)
            case "all":
                await all(state: state, window: window)
            case "edit":
                await edit(editFile, saves: editSaves, state: state, window: window, services: services)
            case "sustain":
                await sustain(seconds: Int(argument) ?? 10, state: state)
            default:
                report("error unknown workload \(workload)")
            }
            quit()
        }

        // MARK: - Workloads

        private static func single(_ fileID: String, state: WindowState, window: NSWindow?) async {
            let loader = state.diffLoader
            let preloaded = loader.content != nil || loader.isLoading
            let before = Sample()
            let start = ContinuousClock.now
            state.selection = [.file(fileID)]
            state.isVisible = true
            let loaded = await wait(window: window) {
                loader.contentFileID == fileID && loader.content != nil && !loader.isLoading
            }
            let visible = ContinuousClock.now - start
            await settle(window: window)
            let delta = Sample() - before
            report(
                "single file=\(fileID) ok=\(loaded) preloaded=\(preloaded) visible=\(ms(visible)) "
                    + "styled=\(loader.styles != nil) \(delta)")
        }

        private static func all(state: WindowState, window: NSWindow?) async {
            let loader = state.diffLoader
            let preloaded = loader.content != nil || loader.isLoading
            let before = Sample()
            let start = ContinuousClock.now
            state.isVisible = true
            state.selection = [.allChanges]
            let published = await wait(window: window) { isChangeset(loader.content) }
            let first = ContinuousClock.now - start
            let finished = await wait(window: window, timeout: .seconds(120)) {
                isChangeset(loader.content) && !loader.isLoading
            }
            let last = ContinuousClock.now - start
            await settle(window: window)
            let delta = Sample() - before
            var sections = 0
            if case let .changeset(document) = loader.content { sections = document.sections.count }
            report(
                "all ok=\(published && finished) preloaded=\(preloaded) sections=\(sections) "
                    + "first=\(ms(first)) last=\(ms(last)) \(delta)")
        }

        private static func edit(
            _ fileID: String, saves: Int, state: WindowState, window: NSWindow?, services: AppServices
        ) async {
            let loader = state.diffLoader
            guard let session = state.session, let root = state.repositoryRoot,
                let file = state.files.first(where: { $0.id == fileID })
            else {
                report("error no file \(fileID)")
                return
            }
            let prefetcher = services.prefetcher
            let client = session.client
            let chained = state.onRefreshPublished
            state.onRefreshPublished = { state, cause, inputsChanged in
                chained?(state, cause, inputsChanged)
                guard inputsChanged || cause != .watcher else { return }
                prefetcher.prefetch(files: state.filesToWarm, repository: root, client: client)
            }
            state.selection = [.file(fileID)]
            state.isVisible = true
            _ = await wait(window: window) {
                loader.contentFileID == fileID && loader.content != nil && !loader.isLoading
            }
            // The first prefetch, as when the window becomes key.
            prefetcher.prefetch(files: state.filesToWarm, repository: root, client: client)
            _ = await wait(window: window, timeout: .seconds(120)) { prefetcher.isIdle }
            await settle(window: window)

            let url = root.url.appendingPathComponent(file.path)
            for save in 1...saves {
                append("// bench edit \(save)\n", to: url)
                let documentBefore = documentID(loader.content)
                let before = Sample()
                let start = ContinuousClock.now
                let refresh = Task { await state.refresh(session: session, cause: .watcher) }
                let loaded = await wait(window: window) {
                    documentID(loader.content) != documentBefore && !loader.isLoading
                }
                let visible = ContinuousClock.now - start
                await refresh.value
                _ = await wait(window: window, timeout: .seconds(120)) { prefetcher.isIdle && !loader.isLoading }
                let idle = ContinuousClock.now - start
                await settle(window: window)
                let delta = Sample() - before
                report(
                    "edit save=\(save) ok=\(loaded) visible=\(ms(visible)) idle=\(ms(idle)) "
                        + "styled=\(loader.styles != nil) \(delta)")
            }
        }

        private static func sustain(seconds: Int, state: WindowState) async {
            guard let root = state.repositoryRoot else { return }
            final class Fires { var times: [Duration] = [] }
            let fires = Fires()
            let start = ContinuousClock.now
            let watcher = RepoWatcher(root: root.url) { _ in fires.times.append(ContinuousClock.now - start) }
            // Let the stream start before the first write.
            try? await Task.sleep(for: .milliseconds(500))
            let writer = Process()
            writer.executableURL = URL(fileURLWithPath: "/bin/sh")
            writer.arguments = [
                "-c",
                "i=0; while [ $i -lt \(seconds * 10) ]; do echo $i >> bench-sustain.txt; i=$((i+1)); sleep 0.1; done",
            ]
            writer.currentDirectoryURL = root.url
            let writeStart = ContinuousClock.now
            do { try writer.run() } catch {
                report("error writer \(error)")
                return
            }
            while writer.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            let writesEnd = ContinuousClock.now - writeStart
            try? await Task.sleep(for: .seconds(2))
            watcher.stop()
            let offset = writeStart - start
            let relative = fires.times.map { ms($0 - offset) }
            let firstFire = relative.first.map(String.init) ?? "none"
            report("sustain writesEnd=\(ms(writesEnd)) firstFire=\(firstFire) fires=\(relative)")
        }

        // MARK: - Helpers

        /// Process launches and pipeline counters at one moment; subtracting gives a delta.
        private struct Sample: CustomStringConvertible {
            var processes = ProcessRunner.allProcesses.reading.launches
            var counts = PipelineMetrics.counts

            static func - (lhs: Sample, rhs: Sample) -> Sample {
                var delta = lhs
                delta.processes -= rhs.processes
                delta.counts.parses -= rhs.counts.parses
                delta.counts.shapedLines -= rhs.counts.shapedLines
                delta.counts.drawNanoseconds -= rhs.counts.drawNanoseconds
                delta.counts.prefetchReads -= rhs.counts.prefetchReads
                delta.counts.prefetchSkips -= rhs.counts.prefetchSkips
                return delta
            }

            var description: String {
                "processes=\(processes) parses=\(counts.parses) shaped=\(counts.shapedLines) "
                    + "drawMs=\(Double(counts.drawNanoseconds / 10_000) / 100) "
                    + "prefetchReads=\(counts.prefetchReads) prefetchSkips=\(counts.prefetchSkips)"
            }
        }

        /// Polls `condition` every 2 ms, displaying the window every 16 ms.
        private static func wait(
            window: NSWindow? = nil, timeout: Duration = .seconds(60), _ condition: @MainActor () -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            var nextDisplay = ContinuousClock.now
            while ContinuousClock.now < deadline {
                if ContinuousClock.now >= nextDisplay {
                    window?.displayIfNeeded()
                    nextDisplay = ContinuousClock.now + .milliseconds(16)
                }
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return condition()
        }

        /// Lets the panes install and draw what was just published.
        private static func settle(window: NSWindow?) async {
            _ = await wait(window: window, timeout: .milliseconds(300)) { false }
        }

        private static func isChangeset(_ content: DiffContent?) -> Bool {
            if case .changeset = content { return true }
            return false
        }

        private static func documentID(_ content: DiffContent?) -> UUID? {
            if case let .text(document) = content { return document.id }
            return nil
        }

        private static func append(_ text: String, to url: URL) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        }

        private static func ms(_ duration: Duration) -> Int {
            Int(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
        }

        private static func report(_ line: String) {
            print("bench \(line)")
            fflush(stdout)
        }

        private static func quit() {
            NSApp.terminate(nil)
        }
    }
#endif
