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

    // MARK: Preserved reloads

    /// A reload of the changeset on screen keeps its document and styles until the whole
    /// replacement is ready, then swaps it in as a new load in one step.
    @Test func aPreservedReloadKeepsTheDocumentUntilTheReplacementIsWhole() async {
        let client = StubRepoClient(files: [])
        let loader = DiffLoader(cache: plainDifftCache())
        let files = [changedFile("a.swift"), changedFile("b.swift")]

        loader.load(changeset: files, client: client, hideWhitespace: true)
        #expect(await eventually { await !loader.hasActiveWork })
        let first = changesetDocument(loader.content)?.loadID
        let styles = loader.styles?.id
        #expect(first != nil && styles != nil)

        await client.hold(worktree: ["a.swift"])
        loader.load(changeset: files, client: client, hideWhitespace: true, preserveCurrentContent: true)
        #expect(await eventually { await client.waitingWorktreePaths.contains("a.swift") })
        #expect(changesetDocument(loader.content)?.loadID == first, "the previous document stays on screen")
        #expect(loader.styles?.id == styles, "with its styles")
        #expect(loader.isLoading)
        #expect(loader.changesetProgress == nil, "a preserved reload reports no progress")

        await client.release(worktree: "a.swift")
        #expect(await eventually { await changesetDocument(loader.content)?.loadID != first })
        let replacement = changesetDocument(loader.content)
        #expect(replacement?.sections.map(\.file.path) == ["a.swift", "b.swift"])
        #expect(loader.styles?.documentID == replacement?.document.id)
        #expect(await eventually { await !loader.hasActiveWork })
    }

    /// Nothing to show is nothing to keep: an empty list clears the panes at once.
    @Test func aPreservedReloadOfAnEmptyListShowsNoChanges() async {
        let client = StubRepoClient(files: [])
        let loader = DiffLoader(cache: plainDifftCache())
        loader.load(changeset: [changedFile("a.swift")], client: client, hideWhitespace: true)
        #expect(await eventually { await !loader.hasActiveWork })

        loader.load(changeset: [], client: client, hideWhitespace: true, preserveCurrentContent: true)
        #expect(loader.content == nil)
        #expect(await eventually { await !loader.isLoading })
        #expect(loader.content == nil)
    }

    /// Preserving only applies to a changeset: a single file on screen belongs to another
    /// selection and is cleared, as for any new changeset.
    @Test func preservingWithoutAChangesetOnScreenStartsFromEmpty() async {
        let client = StubRepoClient(files: [])
        let loader = DiffLoader(cache: plainDifftCache())
        let a = changedFile("a.swift")
        loader.load(file: a, client: client, hideWhitespace: true)
        #expect(await eventually { await loader.content != nil })

        await client.hold(worktree: ["a.swift"])
        loader.load(changeset: [a], client: client, hideWhitespace: true, preserveCurrentContent: true)
        #expect(loader.content == nil, "the file's document is not kept")
        #expect(loader.isLoading)

        await client.release(worktree: "a.swift")
        #expect(await eventually { await changesetDocument(loader.content)?.sections.count == 1 })
        #expect(await eventually { await !loader.hasActiveWork })
    }

    // MARK: Single files

    /// A file's rows and colours are published in one turn, so a reader never sees
    /// the rows uncoloured or the previous file's colours.
    @Test func contentAndStylesArePublishedTogether() async {
        let loader = DiffLoader(cache: plainDifftCache())
        loader.load(file: changedFile("a.swift"), client: StubRepoClient(files: []), hideWhitespace: true)

        #expect(await eventually { await loader.content != nil })
        guard case let .text(document)? = loader.content else {
            Issue.record("text expected")
            return
        }
        #expect(loader.styles?.documentID == document.id)
        #expect(loader.styles?.new?.count == document.newLines.count)
        #expect(!loader.hasActiveWork)
    }

    /// A cache hit for the file on screen keeps the style snapshot it already has; the
    /// same file turning binary clears it, even though the file id did not change.
    @Test func aSameFileHitKeepsItsStylesAndTurningBinaryClearsThem() async {
        let probe = RunnerProbe()
        let cache = DifftCache(runner: { old, new, fileName, qos in
            try await probe.run(old: old, new: new, fileName: fileName, qualityOfService: qos)
        })
        let resultCache = DiffResultCache()
        let client = StubRepoClient(files: [])
        let loader = DiffLoader(cache: cache, resultCache: resultCache)

        loader.load(file: changedFile("a.swift"), client: client, hideWhitespace: true)
        #expect(await eventually { await loader.styles != nil })
        let first = loader.styles?.id
        loader.load(file: changedFile("a.swift"), client: client, hideWhitespace: true)
        #expect(await eventually { await resultCache.stats.hits == 1 })
        #expect(await eventually { await !loader.isLoading })
        guard case let .text(document)? = loader.content else {
            Issue.record("text expected")
            return
        }
        #expect(loader.styles?.documentID == document.id)
        #expect(loader.styles?.id == first, "the snapshot on screen is kept")

        await client.set(worktree: Data([0, 1, 2]), for: "a.swift")
        loader.load(file: changedFile("a.swift"), client: client, hideWhitespace: true)
        #expect(await eventually { await !loader.isLoading })
        guard case .binary? = loader.content else {
            Issue.record("binary expected")
            return
        }
        #expect(loader.styles == nil)
    }
}
