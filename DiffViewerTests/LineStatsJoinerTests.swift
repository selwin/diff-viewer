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
            numstat: [.unstaged: [NumstatEntry(path: "bin.dat", stats: .binary)]],
            to: [changedFile("bin.dat")],
            client: client
        )
        #expect(joined.first?.lineStats == .binary)
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

    @Test func untrackedBinaryFileIsBinary() async {
        #expect(await untrackedStats(Data([0x61, 0x00, 0x62])) == .binary)
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
