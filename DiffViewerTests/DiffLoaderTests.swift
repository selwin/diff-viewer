import CoreGraphics
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

    // MARK: Image previews

    /// True once `loader` has settled on `.binary` content.
    private func waitUntilSettledOnBinary(_ loader: DiffLoader) async -> Bool {
        guard await eventually({ await !loader.isLoading }) else { return false }
        if case .binary? = loader.content { return true }
        return false
    }

    /// The decoded display width of a preview side, or nil when it is absent or undecodable.
    private func decodedWidth(_ side: ImagePreview.Side?) -> CGFloat? {
        guard case let .decoded(decoded)? = side else { return nil }
        return decoded.displaySize.width
    }

    /// A client whose worktree `logo.png` is a 7×5 PNG.
    private func clientWithLogo() async throws -> StubRepoClient {
        let client = StubRepoClient(files: [])
        await client.set(worktree: try imageData(width: 7, height: 5), for: "logo.png")
        return client
    }

    /// A binary file with an image extension publishes its decoded sides with the content;
    /// the stub's text index side is undecodable. One without stays a plain binary.
    @Test func aBinaryImagePublishesAPreviewAndOtherBinariesDoNot() async throws {
        let client = try await clientWithLogo()
        await client.set(worktree: Data([0, 1, 2]), for: "blob.bin")
        let loader = DiffLoader(cache: plainDifftCache())

        loader.load(file: changedFile("logo.png"), client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnBinary(loader))
        #expect(decodedWidth(loader.imagePreview?.new) == 7)
        guard case .undecodable? = loader.imagePreview?.old else {
            Issue.record("undecodable old side expected")
            return
        }
        #expect(loader.styles == nil)

        loader.load(file: changedFile("blob.bin"), client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnBinary(loader))
        #expect(loader.imagePreview == nil)
    }

    /// The image extension may be on the original path of a rename.
    @Test func aRenamedImageIsRecognisedByItsOriginalPath() async throws {
        let client = StubRepoClient(files: [])
        await client.set(worktree: try imageData(width: 7, height: 5), for: "logo.bin")
        let loader = DiffLoader(cache: plainDifftCache())
        let renamed = ChangedFile(
            path: "logo.bin", originalPath: "logo.png", kind: .renamed, area: .unstaged, fingerprint: nil)

        loader.load(file: renamed, client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnBinary(loader))
        #expect(loader.imagePreview != nil)
    }

    /// An untracked image has no old side at all, as opposed to an undecodable one.
    @Test func anUntrackedImageHasNoOldSide() async throws {
        let client = StubRepoClient(files: [])
        await client.set(worktree: try imageData(width: 7, height: 5), for: "new.png")
        let loader = DiffLoader(cache: plainDifftCache())

        loader.load(file: changedFile("new.png", kind: .untracked), client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnBinary(loader))
        #expect(loader.imagePreview?.old == nil)
        #expect(decodedWidth(loader.imagePreview?.new) == 7)
    }

    /// The preview belongs to its selection: another file, no selection, or All changes
    /// clears it at once, before the replacement loads.
    @Test func thePreviewIsClearedWithItsSelection() async throws {
        let client = try await clientWithLogo()
        let loader = DiffLoader(cache: plainDifftCache())
        let loadLogo = {
            loader.load(file: changedFile("logo.png"), client: client, hideWhitespace: true)
            try #require(await waitUntilSettledOnBinary(loader))
            #expect(loader.imagePreview != nil)
        }

        try await loadLogo()
        loader.load(file: changedFile("a.swift"), client: client, hideWhitespace: true)
        #expect(loader.imagePreview == nil, "cleared before the other file loads")
        #expect(await eventually { await !loader.isLoading })
        guard case .text? = loader.content else {
            Issue.record("text expected")
            return
        }
        #expect(loader.imagePreview == nil)

        try await loadLogo()
        loader.load(file: nil, client: client, hideWhitespace: true)
        #expect(loader.imagePreview == nil)

        try await loadLogo()
        loader.load(changeset: [changedFile("a.swift")], client: client, hideWhitespace: true)
        #expect(loader.imagePreview == nil)
        #expect(await eventually { await !loader.hasActiveWork })
    }

    /// Reloading the same file keeps the previous preview on screen until the replacement
    /// is published, as it keeps the content.
    @Test func aSameFileReloadKeepsThePreviewUntilTheReplacementIsPublished() async throws {
        let client = try await clientWithLogo()
        let loader = DiffLoader(cache: plainDifftCache())
        loader.load(file: changedFile("logo.png"), client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnBinary(loader))

        await client.set(worktree: try imageData(width: 3, height: 9), for: "logo.png")
        loader.load(file: changedFile("logo.png"), client: client, hideWhitespace: true)
        #expect(loader.isLoading)
        #expect(decodedWidth(loader.imagePreview?.new) == 7, "the previous preview stays while reloading")
        try #require(await waitUntilSettledOnBinary(loader))
        #expect(decodedWidth(loader.imagePreview?.new) == 3)
    }

    /// A same-file reload whose content is no longer an image drops the preview, whether
    /// the file turned text or merely undecodable.
    @Test func aSameFileReloadThatIsNoLongerAnImageDropsThePreview() async throws {
        let client = try await clientWithLogo()
        let loader = DiffLoader(cache: plainDifftCache())
        loader.load(file: changedFile("logo.png"), client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnBinary(loader))

        await client.set(worktree: Data("text".utf8), for: "logo.png")
        loader.load(file: changedFile("logo.png"), client: client, hideWhitespace: true)
        #expect(await eventually { await !loader.isLoading })
        guard case .text? = loader.content else {
            Issue.record("text expected")
            return
        }
        #expect(loader.imagePreview == nil)

        await client.set(worktree: Data([0, 1, 2]), for: "logo.png")
        loader.load(file: changedFile("logo.png"), client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnBinary(loader))
        #expect(loader.imagePreview == nil)
    }

    /// A superseded image load never publishes its preview, even when its held read comes
    /// back after the newer load has published.
    @Test func aSupersededImageLoadNeverPublishesItsPreview() async throws {
        let client = try await clientWithLogo()
        await client.hold(worktree: ["logo.png"])
        let loader = DiffLoader(cache: plainDifftCache())
        loader.load(file: changedFile("logo.png"), client: client, hideWhitespace: true)
        #expect(await eventually { await client.waitingWorktreePaths.contains("logo.png") })

        loader.load(file: changedFile("a.swift"), client: client, hideWhitespace: true)
        #expect(await eventually { await !loader.isLoading })
        await client.release(worktree: "logo.png")
        try? await Task.sleep(for: .milliseconds(100))
        guard case .text? = loader.content else {
            Issue.record("text expected")
            return
        }
        #expect(loader.imagePreview == nil)
    }

    // MARK: SVG previews

    private func svgData(width: Int, height: Int) -> Data {
        Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\"></svg>".utf8)
    }

    /// True once `loader` has settled on `.text` content.
    private func waitUntilSettledOnText(_ loader: DiffLoader) async -> Bool {
        guard await eventually({ await !loader.isLoading }) else { return false }
        if case .text? = loader.content { return true }
        return false
    }

    /// An SVG is text, so it keeps its text diff and styles and gains a preview. The
    /// stub's index side is plain text, so only the new side decodes.
    @Test func anSVGPublishesBothTextAndAPreview() async throws {
        let client = StubRepoClient(files: [])
        await client.set(worktree: svgData(width: 40, height: 20), for: "icon.svg")
        let loader = DiffLoader(cache: plainDifftCache())

        loader.load(file: changedFile("icon.svg"), client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnText(loader))
        guard case let .text(document)? = loader.content else {
            Issue.record("text expected")
            return
        }
        #expect(loader.styles?.documentID == document.id)
        #expect(decodedWidth(loader.imagePreview?.new) == 40)
    }

    /// Text that is not an SVG at all stays a plain text diff.
    @Test func anInvalidSVGPublishesTextWithoutAPreview() async throws {
        let client = StubRepoClient(files: [])
        await client.set(worktree: Data("not svg at all".utf8), for: "icon.svg")
        let loader = DiffLoader(cache: plainDifftCache())

        loader.load(file: changedFile("icon.svg"), client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnText(loader))
        #expect(loader.imagePreview == nil)
    }

    /// A PNG renamed to an SVG is binary and still previews, each side decoded by the
    /// format of its own name.
    @Test func aPNGRenamedToSVGPreviews() async throws {
        let client = StubRepoClient(files: [])
        await client.set(index: try imageData(width: 7, height: 5), for: "a.png")
        await client.set(worktree: svgData(width: 40, height: 20), for: "icon.svg")
        let loader = DiffLoader(cache: plainDifftCache())
        let renamed = ChangedFile(
            path: "icon.svg", originalPath: "a.png", kind: .renamed, area: .unstaged, fingerprint: nil)

        loader.load(file: renamed, client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnBinary(loader))
        guard case let .decoded(old)? = loader.imagePreview?.old, case let .decoded(new)? = loader.imagePreview?.new
        else {
            Issue.record("both sides decoded expected")
            return
        }
        #expect(old.format == .raster && old.displaySize == CGSize(width: 7, height: 5))
        #expect(new.format == .svg && new.displaySize == CGSize(width: 40, height: 20))
    }

    /// A rename away from an image name keeps the preview: the side that has no format of
    /// its own borrows the other's.
    @Test func aRenameToANonImageNamePreviewsWithTheOriginalFormat() async throws {
        let client = StubRepoClient(files: [])
        await client.set(worktree: svgData(width: 40, height: 20), for: "icon.bin")
        let loader = DiffLoader(cache: plainDifftCache())
        let renamed = ChangedFile(
            path: "icon.bin", originalPath: "icon.svg", kind: .renamed, area: .unstaged, fingerprint: nil)

        loader.load(file: renamed, client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnText(loader))
        #expect(decodedWidth(loader.imagePreview?.new) == 40)
    }

    /// An untracked SVG has no old side at all.
    @Test func anUntrackedSVGHasNoOldSide() async throws {
        let client = StubRepoClient(files: [])
        await client.set(worktree: svgData(width: 12, height: 8), for: "new.svg")
        let loader = DiffLoader(cache: plainDifftCache())

        loader.load(file: changedFile("new.svg", kind: .untracked), client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnText(loader))
        #expect(loader.imagePreview?.old == nil)
        #expect(decodedWidth(loader.imagePreview?.new) == 12)
    }

    /// Selecting a source file after an SVG clears the preview, as for any other selection.
    @Test func selectingAnotherFileClearsTheSVGPreview() async throws {
        let client = StubRepoClient(files: [])
        await client.set(worktree: svgData(width: 40, height: 20), for: "icon.svg")
        let loader = DiffLoader(cache: plainDifftCache())
        loader.load(file: changedFile("icon.svg"), client: client, hideWhitespace: true)
        try #require(await waitUntilSettledOnText(loader))
        #expect(loader.imagePreview != nil)

        loader.load(file: changedFile("a.swift"), client: client, hideWhitespace: true)
        #expect(loader.imagePreview == nil)
        try #require(await waitUntilSettledOnText(loader))
        #expect(loader.imagePreview == nil)
    }
}
