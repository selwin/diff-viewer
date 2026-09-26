import Testing

@testable import DiffViewer

struct StagingTraySummaryTests {
    private static func staged(_ path: String, _ stats: LineStats? = nil) -> ChangedFile {
        changedFile(path, area: .staged).with(lineStats: stats)
    }

    @Test func oneFileIsSingular() {
        let summary = StagingTraySummary(stagedFiles: [Self.staged("a.swift")], isMerging: false)
        #expect(summary.fileCountText == "1 file")
        #expect(summary.commitTitle == "Commit 1 File")
    }

    @Test func severalFilesArePlural() {
        let summary = StagingTraySummary(
            stagedFiles: [Self.staged("a.swift"), Self.staged("b.swift")], isMerging: false)
        #expect(summary.fileCountText == "2 files")
        #expect(summary.commitTitle == "Commit 2 Files")
    }

    /// A merge with nothing staged is still a commit to make; one with staged files counts them.
    @Test func aMergeWithNothingStagedCommitsTheMerge() {
        let empty = StagingTraySummary(stagedFiles: [], isMerging: true)
        #expect(empty.fileCountText == "0 files")
        #expect(empty.commitTitle == "Commit Merge")
        let staged = StagingTraySummary(stagedFiles: [Self.staged("a.swift")], isMerging: true)
        #expect(staged.commitTitle == "Commit 1 File")
    }

    @Test func churnIsNilUntilCountsArriveAndForBinariesOnly() {
        #expect(StagingTraySummary(stagedFiles: [Self.staged("a.swift")], isMerging: false).churn == nil)
        let binaries = [Self.staged("a.png", .binary(nil)), Self.staged("b.png", .binary(nil))]
        #expect(StagingTraySummary(stagedFiles: binaries, isMerging: false).churn == nil)
    }

    @Test func labelsSpeakTheChurnOnlyWhenCounted() {
        let counted = StagingTraySummary(
            stagedFiles: [Self.staged("a.swift", .counted(added: 12, deleted: 1))], isMerging: false)
        #expect(counted.churn == .counted(added: 12, deleted: 1))
        #expect(counted.headerAccessibilityLabel == "Staged, 1 file, 12 additions, 1 deletion")
        #expect(counted.commitAccessibilityLabel == "Commit 1 File, 12 additions, 1 deletion")

        let uncounted = StagingTraySummary(stagedFiles: [Self.staged("a.png", .binary(nil))], isMerging: false)
        #expect(uncounted.headerAccessibilityLabel == "Staged, 1 file")
        #expect(uncounted.commitAccessibilityLabel == "Commit 1 File")
    }
}
