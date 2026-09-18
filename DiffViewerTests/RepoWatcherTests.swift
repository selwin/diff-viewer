import Foundation
import Testing

@testable import DiffViewer

/// The watcher's callback side driven by hand, so no real filesystem event is needed:
/// what the filter drops never arms the debounce, and what survives arrives merged.
@MainActor
final class RepoWatcherTests {
    @MainActor
    final class Recorder {
        var batches: [Set<RepoChange>] = []
    }

    private let directory: URL
    private let root: String

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DiffViewerWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // As FSEvents would report it: `realpath`, since Foundation's resolver keeps `/var`.
        let resolved = try #require(realpath(directory.path, nil))
        root = String(cString: resolved)
        free(resolved)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeWatcher() -> (RepoWatcher, Recorder) {
        let recorder = Recorder()
        let watcher = RepoWatcher(root: directory, interval: .milliseconds(10)) { recorder.batches.append($0) }
        return (watcher, recorder)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func aRelevantPathIsDeliveredClassified() async throws {
        let (watcher, recorder) = makeWatcher()
        defer { watcher.stop() }

        watcher.simulate(paths: [root + "/.git/index"], flags: [0])

        #expect(await eventually { await recorder.batches == [[.index]] })
    }

    /// A template under `.git` would otherwise be dropped with that directory's noise.
    /// Resolved through its directory, so a template that does not exist yet still counts.
    @Test func aDependencyUnderGitIsDelivered() async throws {
        let (watcher, recorder) = makeWatcher()
        defer { watcher.stop() }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        watcher.setDependencies([directory.appendingPathComponent(".git/commit-template").path])

        watcher.simulate(paths: [root + "/.git/commit-template"], flags: [0])
        #expect(await eventually { await recorder.batches == [[.commitState]] })

        watcher.setDependencies([])
        watcher.simulate(paths: [root + "/.git/commit-template"], flags: [0])
        await settle()
        #expect(recorder.batches.count == 1, "no longer a dependency, so dropped again")
    }

    /// A template that is a symlink is watched at both ends: an edit arrives as the
    /// target's path, and replacing, deleting or retargeting the link as the link's own.
    @Test func aSymlinkedDependencyIsWatchedAtTheLinkAndItsTarget() async throws {
        let (watcher, recorder) = makeWatcher()
        defer { watcher.stop() }
        let git = directory.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("A\n".utf8).write(to: git.appendingPathComponent("template-A"))
        try FileManager.default.createSymbolicLink(
            atPath: git.appendingPathComponent("commit-template").path, withDestinationPath: "template-A")
        watcher.setDependencies([git.appendingPathComponent("commit-template").path])

        watcher.simulate(paths: [root + "/.git/template-A"], flags: [0])
        #expect(await eventually { await recorder.batches == [[.commitState]] }, "an edit through the link")
        watcher.simulate(paths: [root + "/.git/commit-template"], flags: [0])
        #expect(await eventually { await recorder.batches.count == 2 }, "the link itself replaced or deleted")
        watcher.simulate(paths: [root + "/.git/template-B"], flags: [0])
        await settle()
        #expect(recorder.batches.count == 2, "a file the link does not point at yet is noise")
    }

    /// Opened through a symlinked root (`/tmp` → `/private/tmp`), with the template's
    /// directory not there yet: the nearest existing ancestor is what FSEvents will name.
    @Test func aDependencyUnderMissingDirectoriesIsCanonicalised() async throws {
        let (watcher, recorder) = makeWatcher()
        defer { watcher.stop() }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git"), withIntermediateDirectories: true)
        watcher.setDependencies([directory.appendingPathComponent(".git/templates/nested/message").path])

        watcher.simulate(paths: [root + "/.git/templates/nested/message"], flags: [0])
        #expect(await eventually { await recorder.batches == [[.commitState]] })
    }

    @Test func aDroppedPathArmsNothing() async throws {
        let (watcher, recorder) = makeWatcher()
        defer { watcher.stop() }

        watcher.simulate(paths: [root + "/.git/FETCH_HEAD", root + "/.git/objects/ab/cd"], flags: [0, 0])
        await settle()

        #expect(recorder.batches.isEmpty)
    }

    @Test func eventsWithinTheDebounceArriveAsOneMergedSet() async throws {
        let (watcher, recorder) = makeWatcher()
        defer { watcher.stop() }

        watcher.simulate(paths: [root + "/src/a.swift"], flags: [0])
        watcher.simulate(paths: [root + "/.git/refs/heads/main", root + "/.git/logs/HEAD"], flags: [0, 0])

        #expect(await eventually { await recorder.batches == [[.worktree, .refs]] })
        await settle()
        #expect(recorder.batches.count == 1)
    }

    @Test func nothingIsDeliveredAfterStop() async throws {
        let (watcher, recorder) = makeWatcher()
        watcher.stop()

        watcher.simulate(paths: [root + "/.git/index"], flags: [0])
        await settle()

        #expect(recorder.batches.isEmpty)
    }
}
