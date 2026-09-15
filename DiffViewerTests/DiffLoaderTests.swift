import Foundation
import Testing

@testable import DiffViewer

/// The changeset a loader is publishing, or nil when it is showing anything else.
private func changesetDocument(_ content: DiffContent?) -> ChangesetDocument? {
    guard case let .changeset(document)? = content else { return nil }
    return document
}

/// A cache whose difft always fails, so every file falls back to the plain line diff.
private func plainDifftCache() -> DifftCache {
    DifftCache(runner: { _, _, _, _ in throw ProcessError.failed(command: "difft", status: 1, stderr: "no difft") })
}

@MainActor
struct DiffLoaderTests {
    /// A superseded changeset load must stay superseded. Its held read comes back long
    /// after a newer load has published, and the panes must not revert to the old list.
    @Test func aSupersededChangesetLoadNeverPublishes() async {
        let client = StubRepoClient(files: [])
        await client.hold(worktree: ["a.swift"])
        let loader = DiffLoader(cache: plainDifftCache())

        loader.load(changeset: [changedFile("a.swift"), changedFile("b.swift")], client: client, hideWhitespace: true)
        #expect(await eventually { await client.waitingWorktreePaths.contains("a.swift") })
        #expect(loader.content == nil, "the held first file holds the whole prefix back")

        loader.load(changeset: [changedFile("c.swift")], client: client, hideWhitespace: true)
        #expect(
            await eventually { await changesetDocument(loader.content)?.sections.map(\.file.path) == ["c.swift"] })
        #expect(await eventually { await !loader.hasActiveWork })
        let second = changesetDocument(loader.content)

        await client.release(worktree: "a.swift")
        try? await Task.sleep(for: .milliseconds(100))
        let current = changesetDocument(loader.content)
        #expect(current?.loadID == second?.loadID, "still the second load's document")
        #expect(current?.sections.map(\.file.path) == ["c.swift"])
        #expect(loader.styles?.documentID == current?.document.id)
    }
}
