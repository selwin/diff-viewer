import Foundation
import Testing

@testable import DiffViewer

struct LineStatsJoinerTests {
    private func stats(_ files: [ChangedFile], _ id: ChangedFile.ID) -> LineStats? {
        files.first { $0.id == id }?.lineStats
    }

    @Test func rowsLandOnTheMatchingArea() async {
        let client = StubRepoClient(files: [])
        let files = [changedFile("a.txt", area: .staged), changedFile("a.txt", area: .unstaged)]
        let joined = await LineStatsJoiner.attach(
            numstat: [
                .staged: [NumstatEntry(path: "a.txt", stats: .counted(added: 1, deleted: 2))],
                .unstaged: [NumstatEntry(path: "a.txt", stats: .counted(added: 30, deleted: 40))],
            ],
            to: files,
            client: client
        )
        #expect(stats(joined, "staged:a.txt") == .counted(added: 1, deleted: 2))
        #expect(stats(joined, "unstaged:a.txt") == .counted(added: 30, deleted: 40))
    }

    @Test func fileWithoutARowInAReportedAreaHasZeroChurn() async {
        // git omits files with no difference, e.g. a whitespace-only edit under -w.
        let client = StubRepoClient(files: [])
        let joined = await LineStatsJoiner.attach(
            numstat: [.unstaged: [NumstatEntry(path: "other.txt", stats: .counted(added: 1, deleted: 1))]],
            to: [changedFile("a.txt")],
            client: client
        )
        #expect(joined.first?.lineStats == .counted(added: 0, deleted: 0))
    }

    @Test func fileInAnUnreportedAreaStaysUnknown() async {
        let client = StubRepoClient(files: [])
        let joined = await LineStatsJoiner.attach(
            numstat: [.staged: [NumstatEntry(path: "a.txt", stats: .counted(added: 1, deleted: 1))]],
            to: [changedFile("a.txt", area: .unstaged)],
            client: client
        )
        #expect(joined.first?.lineStats == nil)
    }

    @Test func binaryRowBecomesBinary() async {
        let client = StubRepoClient(files: [])
        let joined = await LineStatsJoiner.attach(
            numstat: [.unstaged: [NumstatEntry(path: "bin.dat", stats: .binary(nil))]],
            to: [changedFile("bin.dat")],
            client: client
        )
        #expect(joined.first?.lineStats == .binary(nil))
    }

    @Test func firstRowWinsForDuplicatePaths() async {
        let client = StubRepoClient(files: [])
        let joined = await LineStatsJoiner.attach(
            numstat: [
                .unstaged: [
                    NumstatEntry(path: "a.txt", stats: .counted(added: 0, deleted: 0)),
                    NumstatEntry(path: "a.txt", stats: .counted(added: 99, deleted: 99)),
                ]
            ],
            to: [changedFile("a.txt")],
            client: client
        )
        #expect(joined.first?.lineStats == .counted(added: 0, deleted: 0))
    }

    @Test func unmergedStaysUnknownEvenWithRows() async {
        let client = StubRepoClient(files: [])
        let joined = await LineStatsJoiner.attach(
            numstat: [.unstaged: [NumstatEntry(path: "conflict.txt", stats: .counted(added: 7, deleted: 7))]],
            to: [changedFile("conflict.txt", kind: .unmerged)],
            client: client
        )
        #expect(joined.first?.lineStats == nil)
    }

    // MARK: untracked

    private func untrackedStats(_ contents: Data?) async -> LineStats? {
        let client = StubRepoClient(files: [])
        await client.set(worktree: contents, for: "new.txt")
        let joined = await LineStatsJoiner.attach(
            numstat: [:],
            to: [changedFile("new.txt", kind: .untracked)],
            client: client
        )
        return joined.first?.lineStats
    }

    @Test func untrackedWithTrailingNewlineCountsItsLines() async {
        #expect(await untrackedStats(Data("a\nb\nc\n".utf8)) == .counted(added: 3, deleted: 0))
    }

    @Test func untrackedWithoutTrailingNewlineCountsTheLastLine() async {
        #expect(await untrackedStats(Data("a\nb\nc".utf8)) == .counted(added: 3, deleted: 0))
    }

    @Test func untrackedEmptyFileCountsZero() async {
        #expect(await untrackedStats(Data()) == .counted(added: 0, deleted: 0))
    }

    @Test func untrackedBinaryFileIsBinaryWithItsByteCount() async {
        #expect(
            await untrackedStats(Data([0x61, 0x00, 0x62]))
                == .binary(BinarySizes(oldByteCount: nil, newByteCount: 3)))
    }

    @Test func untrackedMissingFileStaysUnknown() async {
        #expect(await untrackedStats(nil) == nil)
    }

    @Test func untrackedRowsAreIgnoredInFavourOfTheWorktree() async {
        let client = StubRepoClient(files: [])
        await client.set(worktree: Data("a\nb\n".utf8), for: "new.txt")
        let joined = await LineStatsJoiner.attach(
            numstat: [.unstaged: [NumstatEntry(path: "new.txt", stats: .counted(added: 99, deleted: 99))]],
            to: [changedFile("new.txt", kind: .untracked)],
            client: client
        )
        #expect(joined.first?.lineStats == .counted(added: 2, deleted: 0))
    }

    @Test func orderAndCountSurviveManyConcurrentReads() async {
        let client = StubRepoClient(files: [])
        let paths = (0..<12).map { "u\($0).txt" }
        for (index, path) in paths.enumerated() {
            await client.set(worktree: Data(String(repeating: "x\n", count: index + 1).utf8), for: path)
        }
        var files = paths.map { changedFile($0, kind: .untracked) }
        files.insert(changedFile("tracked.txt"), at: 5)

        let joined = await LineStatsJoiner.attach(
            numstat: [.unstaged: [NumstatEntry(path: "tracked.txt", stats: .counted(added: 1, deleted: 1))]],
            to: files,
            client: client
        )
        #expect(joined.count == files.count)
        #expect(joined.map(\.path) == files.map(\.path))
        #expect(stats(joined, "unstaged:tracked.txt") == .counted(added: 1, deleted: 1))
        for (index, path) in paths.enumerated() {
            #expect(stats(joined, "unstaged:\(path)") == .counted(added: index + 1, deleted: 0))
        }
    }

    @Test func atMostEightWorktreeReadsRunAtOnce() async {
        let client = StubRepoClient(files: [])
        let paths = (0..<12).map { "u\($0).txt" }
        for (index, path) in paths.enumerated() {
            await client.set(worktree: Data(String(repeating: "x\n", count: index + 1).utf8), for: path)
        }
        await client.holdReads(true)

        let files = paths.map { changedFile($0, kind: .untracked) }
        let joining = Task { await LineStatsJoiner.attach(numstat: [:], to: files, client: client) }

        #expect(await eventually { await client.heldReadCount == 8 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await client.heldReadCount == 8)

        // releaseReads only resumes the reads held right now, so the last four need a
        // second release once the top-up tasks have parked.
        await client.releaseReads()
        #expect(await eventually { await client.heldReadCount == 4 })
        await client.releaseReads()

        let joined = await joining.value
        for (index, path) in paths.enumerated() {
            #expect(stats(joined, "unstaged:\(path)") == .counted(added: index + 1, deleted: 0))
        }
    }

    /// Counting is decoration: a file that cannot be read has unknown stats, exactly as a
    /// missing one does, and never fails the list it decorates.
    @Test func aWorktreeReadFailureLeavesTheStatsUnknown() async {
        let client = StubRepoClient(files: [])
        await client.fail(worktree: ["locked.txt"])
        await client.set(worktree: Data("one\ntwo\n".utf8), for: "readable.txt")

        let joined = await LineStatsJoiner.attach(
            numstat: [:],
            to: [changedFile("locked.txt", kind: .untracked), changedFile("readable.txt", kind: .untracked)],
            client: client
        )
        #expect(stats(joined, "unstaged:locked.txt") == nil)
        #expect(stats(joined, "unstaged:readable.txt") == .counted(added: 2, deleted: 0))
    }

    // MARK: binary sizes

    private typealias Source = LineStatsJoiner.BinarySizeSource

    private let ref = CommitRef(sha: objectID("c"), shortSha: "c", firstParentSHA: objectID("p"))
    private let rootRef = CommitRef(sha: objectID("root"), shortSha: "root", firstParentSHA: nil)

    private func commitFile(
        _ path: String, originalPath: String? = nil, kind: ChangedFile.Kind = .modified, in ref: CommitRef
    ) -> ChangedFile {
        ChangedFile(path: path, originalPath: originalPath, kind: kind, area: .commit(ref), fingerprint: nil)
    }

    private func binaryRow(_ path: String) -> NumstatEntry { NumstatEntry(path: path, stats: .binary(nil)) }

    private func sizes(_ old: Int64?, _ new: Int64?) -> LineStats {
        .binary(BinarySizes(oldByteCount: old, newByteCount: new))
    }

    @Test func sizeSourcesReadTheWorkingTreeFingerprint() {
        #expect(
            LineStatsJoiner.sizeSources(for: changedFile("a.png", area: .staged))
                == (.spec(objectID("head-a.png")), .spec(objectID("index-a.png"))))
        #expect(
            LineStatsJoiner.sizeSources(for: changedFile("a.png")) == (.spec(objectID("index-a.png")), .byteCount(10)))
    }

    @Test func sizeSourcesTreatTheZeroHashAndAMissingFileAsAbsent() {
        let staged = changedFile("a.png", area: .staged, kind: .added)
        let stagedAdd = staged.with(
            fingerprint: DiffInputFingerprint(
                old: .absent, new: .object(objectID("index-a.png")), worktree: .notApplicable, kind: .added,
                originalPath: nil))
        #expect(LineStatsJoiner.sizeSources(for: stagedAdd) == (.absent, .spec(objectID("index-a.png"))))

        let deleted = changedFile("a.png", kind: .deleted).with(
            fingerprint: DiffInputFingerprint(
                old: .object(objectID("index-a.png")), new: .notApplicable, worktree: .missing, kind: .deleted,
                originalPath: nil))
        #expect(LineStatsJoiner.sizeSources(for: deleted) == (.spec(objectID("index-a.png")), .absent))
    }

    @Test func sizeSourcesForACommitFollowTheChangeKind() {
        let parent = objectID("p")
        let sha = objectID("c")
        #expect(
            LineStatsJoiner.sizeSources(for: commitFile("a.png", in: ref))
                == (.spec("\(parent):a.png"), .spec("\(sha):a.png")))
        #expect(
            LineStatsJoiner.sizeSources(for: commitFile("a.png", kind: .added, in: ref))
                == (.absent, .spec("\(sha):a.png")))
        #expect(
            LineStatsJoiner.sizeSources(for: commitFile("a.png", kind: .deleted, in: ref))
                == (.spec("\(parent):a.png"), .absent))
        #expect(
            LineStatsJoiner.sizeSources(for: commitFile("a.png", in: rootRef))
                == (.absent, .spec("\(objectID("root")):a.png")))
    }

    @Test func sizeSourcesUseTheOriginalPathForACommitsOldSide() {
        let renamed = commitFile("new.png", originalPath: "old.png", kind: .renamed, in: ref)
        #expect(
            LineStatsJoiner.sizeSources(for: renamed)
                == (.spec("\(objectID("p")):old.png"), .spec("\(objectID("c")):new.png")))
    }

    @Test func sizeSourcesAreUnknownForAPathWithANewline() {
        let sources = LineStatsJoiner.sizeSources(for: commitFile("bad\nname.png", in: ref))
        #expect(sources == (.unknown, .unknown))
    }

    @Test func trackedOnlyListGetsSizes() async {
        let client = StubRepoClient(files: [])
        await client.set(objectSize: 1_000, for: objectID("index-a.png"))
        await client.set(objectSize: 1_000, for: objectID("head-b.png"))
        await client.set(objectSize: 25_000, for: objectID("index-b.png"))
        let joined = await LineStatsJoiner.attach(
            numstat: [.unstaged: [binaryRow("a.png")], .staged: [binaryRow("b.png")]],
            to: [changedFile("a.png"), changedFile("b.png", area: .staged)],
            client: client
        )
        #expect(stats(joined, "unstaged:a.png") == sizes(1_000, 10))
        #expect(stats(joined, "staged:b.png") == sizes(1_000, 25_000))
    }

    @Test func commitScopeListGetsSizes() async {
        let client = StubRepoClient(files: [])
        await client.set(objectSize: 1_000, for: "\(objectID("p")):a.png")
        await client.set(objectSize: 25_000, for: "\(objectID("c")):a.png")
        await client.set(objectSize: 640_000, for: "\(objectID("c")):b.png")
        let joined = await LineStatsJoiner.attach(
            numstat: [.commit(ref): [binaryRow("a.png"), binaryRow("b.png")]],
            to: [commitFile("a.png", in: ref), commitFile("b.png", kind: .added, in: ref)],
            client: client
        )
        #expect(stats(joined, "commit:\(objectID("c")):a.png") == sizes(1_000, 25_000))
        #expect(stats(joined, "commit:\(objectID("c")):b.png") == sizes(nil, 640_000))
        #expect(await client.objectSizesCalls.count == 1)
    }

    @Test func sizesLandOnTheFileThatAskedForThem() async {
        let client = StubRepoClient(files: [])
        await client.set(objectSize: 1_000, for: objectID("head-a.png"))
        await client.set(objectSize: 25_000, for: objectID("index-a.png"))
        await client.set(objectSize: 640_000, for: objectID("head-b.png"))
        await client.set(objectSize: 1_000, for: objectID("index-b.png"))
        let joined = await LineStatsJoiner.attach(
            numstat: [.staged: [binaryRow("a.png"), binaryRow("b.png")]],
            to: [changedFile("a.png", area: .staged), changedFile("b.png", area: .staged)],
            client: client
        )
        #expect(stats(joined, "staged:a.png") == sizes(1_000, 25_000))
        #expect(stats(joined, "staged:b.png") == sizes(640_000, 1_000))
    }

    /// A lookup that fails is never an absent side: the file stays "binary" rather than
    /// rendering as added or deleted, and its neighbours still resolve.
    @Test func anUnresolvedSpecLeavesOnlyItsFileWithoutSizes() async {
        let client = StubRepoClient(files: [])
        await client.set(objectSize: 1_000, for: objectID("index-a.png"))
        await client.set(objectSize: 25_000, for: objectID("head-b.png"))
        await client.set(objectSize: 640_000, for: objectID("index-b.png"))
        let joined = await LineStatsJoiner.attach(
            numstat: [.staged: [binaryRow("a.png"), binaryRow("b.png")]],
            to: [changedFile("a.png", area: .staged), changedFile("b.png", area: .staged)],
            client: client
        )
        #expect(stats(joined, "staged:a.png") == .binary(nil))
        #expect(stats(joined, "staged:b.png") == sizes(25_000, 640_000))
    }

    @Test func aRepeatedSpecIsRequestedOnceAndReachesEveryDependent() async {
        // Two files whose old sides are the same blob: identical content shares an id.
        let shared = objectID("shared")
        let a = changedFile("a.png", area: .staged).with(
            fingerprint: DiffInputFingerprint(
                old: .object(shared), new: .object(objectID("index-a.png")), worktree: .notApplicable,
                kind: .modified, originalPath: nil))
        let b = changedFile("b.png", area: .staged).with(
            fingerprint: DiffInputFingerprint(
                old: .object(shared), new: .object(objectID("index-b.png")), worktree: .notApplicable,
                kind: .modified, originalPath: nil))
        let client = StubRepoClient(files: [])
        await client.set(objectSize: 1_000, for: shared)
        await client.set(objectSize: 25_000, for: objectID("index-a.png"))
        await client.set(objectSize: 640_000, for: objectID("index-b.png"))
        let joined = await LineStatsJoiner.attach(
            numstat: [.staged: [binaryRow("a.png"), binaryRow("b.png")]], to: [a, b], client: client)
        #expect(stats(joined, "staged:a.png") == sizes(1_000, 25_000))
        #expect(stats(joined, "staged:b.png") == sizes(1_000, 640_000))
        #expect(await client.objectSizesCalls == [[shared, objectID("index-a.png"), objectID("index-b.png")]])
    }

    @Test func aNewlinePathStaysWithoutSizesAndDoesNotBlockTheRest() async {
        let client = StubRepoClient(files: [])
        await client.set(objectSize: 1_000, for: "\(objectID("p")):ok.png")
        await client.set(objectSize: 25_000, for: "\(objectID("c")):ok.png")
        let joined = await LineStatsJoiner.attach(
            numstat: [.commit(ref): [binaryRow("bad\nname.png"), binaryRow("ok.png")]],
            to: [commitFile("bad\nname.png", in: ref), commitFile("ok.png", in: ref)],
            client: client
        )
        #expect(stats(joined, "commit:\(objectID("c")):bad\nname.png") == .binary(nil))
        #expect(stats(joined, "commit:\(objectID("c")):ok.png") == sizes(1_000, 25_000))
        #expect(await client.objectSizesCalls.flatMap { $0 }.allSatisfy { !$0.contains("\n") })
    }

    /// "\r\n" is one Character, so a Character search for "\n" would miss it.
    @Test func aCRLFPathStaysWithoutSizesAndDoesNotBlockTheRest() async {
        let client = StubRepoClient(files: [])
        await client.set(objectSize: 1_000, for: "\(objectID("p")):ok.png")
        await client.set(objectSize: 25_000, for: "\(objectID("c")):ok.png")
        let joined = await LineStatsJoiner.attach(
            numstat: [.commit(ref): [binaryRow("bad\r\nname.png"), binaryRow("ok.png")]],
            to: [commitFile("bad\r\nname.png", in: ref), commitFile("ok.png", in: ref)],
            client: client
        )
        #expect(stats(joined, "commit:\(objectID("c")):bad\r\nname.png") == .binary(nil))
        #expect(stats(joined, "commit:\(objectID("c")):ok.png") == sizes(1_000, 25_000))
        #expect(await client.objectSizesCalls.flatMap { $0 }.allSatisfy { !$0.utf8.contains(0x0A) })
    }

    /// Git strips a CR before the line terminator, so this path would be sized as "bad.png".
    @Test func aTrailingCRPathStaysWithoutSizesAndDoesNotBlockTheRest() async {
        let client = StubRepoClient(files: [])
        await client.set(objectSize: 1_000, for: "\(objectID("p")):ok.png")
        await client.set(objectSize: 25_000, for: "\(objectID("c")):ok.png")
        let joined = await LineStatsJoiner.attach(
            numstat: [.commit(ref): [binaryRow("bad.png\r"), binaryRow("ok.png")]],
            to: [commitFile("bad.png\r", in: ref), commitFile("ok.png", in: ref)],
            client: client
        )
        #expect(stats(joined, "commit:\(objectID("c")):bad.png\r") == .binary(nil))
        #expect(stats(joined, "commit:\(objectID("c")):ok.png") == sizes(1_000, 25_000))
        #expect(await client.objectSizesCalls.flatMap { $0 }.allSatisfy { !GitClient.breaksLineFraming($0) })
    }

    @Test func aFingerprintOnlyFileResolvesEvenWhenTheBatchThrows() async {
        let added = changedFile("new.png", kind: .added).with(
            fingerprint: DiffInputFingerprint(
                old: .absent, new: .notApplicable,
                worktree: .file(mtimeNs: 1, ctimeNs: 1, size: 640_000, inode: 1), kind: .added, originalPath: nil))
        let client = StubRepoClient(files: [])
        await client.fail(objectSizes: true)
        let joined = await LineStatsJoiner.attach(
            numstat: [.unstaged: [binaryRow("new.png"), binaryRow("a.png")]],
            to: [added, changedFile("a.png")],
            client: client
        )
        #expect(stats(joined, "unstaged:new.png") == sizes(nil, 640_000))
        #expect(stats(joined, "unstaged:a.png") == .binary(nil))
    }

    @Test func aCountMismatchLeavesTheFileWithoutSizes() async {
        let client = StubRepoClient(files: [])
        await client.set(objectSize: 1_000, for: objectID("head-a.png"))
        await client.set(objectSize: 25_000, for: objectID("index-a.png"))
        await client.truncate(objectSizes: true)
        let joined = await LineStatsJoiner.attach(
            numstat: [.staged: [binaryRow("a.png")]], to: [changedFile("a.png", area: .staged)], client: client)
        #expect(stats(joined, "staged:a.png") == .binary(nil))
    }

    @Test func noBatchRunsWhenNothingNeedsGit() async {
        let client = StubRepoClient(files: [])
        let counted = await LineStatsJoiner.attach(
            numstat: [.unstaged: [NumstatEntry(path: "a.txt", stats: .counted(added: 1, deleted: 1))]],
            to: [changedFile("a.txt")],
            client: client
        )
        #expect(counted.first?.lineStats == .counted(added: 1, deleted: 1))
        #expect(await client.objectSizesCalls.isEmpty)

        await client.set(worktree: Data([0x89, 0x50, 0]), for: "new.png")
        let added = changedFile("added.png", kind: .added).with(
            fingerprint: DiffInputFingerprint(
                old: .absent, new: .notApplicable,
                worktree: .file(mtimeNs: 1, ctimeNs: 1, size: 1_000, inode: 1), kind: .added, originalPath: nil))
        let joined = await LineStatsJoiner.attach(
            numstat: [.unstaged: [binaryRow("added.png")]],
            to: [changedFile("new.png", kind: .untracked), added],
            client: client
        )
        #expect(stats(joined, "unstaged:new.png") == sizes(nil, 3))
        #expect(stats(joined, "unstaged:added.png") == sizes(nil, 1_000))
        #expect(await client.objectSizesCalls.isEmpty)
    }

    @Test func cancellationBeforeTheBatchLeavesBinaryWithoutSizes() async {
        let client = StubRepoClient(files: [])
        await client.set(objectSize: 1_000, for: objectID("index-a.png"))
        await client.holdReads(true)
        let files = [changedFile("new.txt", kind: .untracked), changedFile("a.png")]
        let joining = Task {
            await LineStatsJoiner.attach(numstat: [.unstaged: [binaryRow("a.png")]], to: files, client: client)
        }
        #expect(await eventually { await client.heldReadCount == 1 })
        joining.cancel()
        await client.releaseReads()

        let joined = await joining.value
        #expect(stats(joined, "unstaged:a.png") == .binary(nil))
        #expect(await client.objectSizesCalls.isEmpty)
    }

    // MARK: line counting

    @Test func lineCountMatchesTextLinesSplit() {
        #expect(LineStatsJoiner.lineCount(Data()) == 0)
        #expect(LineStatsJoiner.lineCount(Data("a\nb\n".utf8)) == 2)
        #expect(LineStatsJoiner.lineCount(Data("a\nb".utf8)) == 2)
        #expect(LineStatsJoiner.lineCount(Data("\n".utf8)) == 1)
        #expect(LineStatsJoiner.lineCount(Data("a\n\nb\n".utf8)) == 3)

        for text in ["", "a\nb\n", "a\nb", "\n", "a\n\nb\n"] {
            #expect(LineStatsJoiner.lineCount(Data(text.utf8)) == TextLines.split(text).count)
        }
    }
}
