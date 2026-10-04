import Testing

@testable import DiffViewer

struct HeadChangeActivityTests {
    private func activity(_ state: HeadChangeActivity.State) -> HeadChangeActivity {
        HeadChangeActivity(activityID: 1, state: state)
    }

    private func shown(_ activity: HeadChangeActivity) -> [String] {
        [activity.title, activity.detail]
    }

    @Test func runningTextNamesTheBranchBeingChanged() {
        let target = MergeTarget(
            sourceName: "fix/x", sourceRef: "refs/heads/fix/x", sourceTipSha: "s", destinationBranch: "main",
            destinationTipSha: "m")
        let running: [(HeadChange, [String])] = [
            (.switchTo("main"), ["Switching to", "main"]),
            (.checkoutTracking(remoteBranch("feature/y")), ["Switching to", "feature/y"]),
            (.create("feature/y"), ["Creating", "feature/y"]),
            (.merge(target), ["Merging", "fix/x"]),
        ]
        for (change, text) in running {
            let item = activity(.running(change))
            #expect(shown(item) == text)
            #expect(item.tone == .progress)
        }
    }

    @Test func finishedTextAndTone() {
        let finished: [(HeadChangeOutcome, [String], HeadChangeActivity.Tone)] = [
            (.switched(to: "main"), ["Switched to", "main"], .success),
            (.created("feature/y"), ["Created", "feature/y"], .success),
            (.merged(source: "fix/x", kind: .mergeCommit, commitCount: 4), ["Merged", "fix/x · 4 commits"], .success),
            (
                .merged(source: "fix/x", kind: .fastForward, commitCount: 4),
                ["Fast-forwarded", "fix/x · 4 commits"], .success
            ),
            (.merged(source: "fix/x", kind: .unknown, commitCount: 4), ["Merged", "fix/x · 4 commits"], .success),
            (
                .merged(source: "fix/x", kind: .alreadyUpToDate, commitCount: nil), ["Already up to date", "fix/x"],
                .success
            ),
            (
                .mergeStopped(source: "fix/x", conflictFileCount: 2), ["Merge stopped", "conflicts in 2 files"],
                .warning
            ),
        ]
        for (outcome, text, tone) in finished {
            let item = activity(.finished(outcome))
            #expect(shown(item) == text)
            #expect(item.tone == tone)
        }
    }

    @Test func countsArePluralisedAndAMissingCountLeavesTheSuffixOff() {
        #expect(activity(.finished(.merged(source: "a", kind: .mergeCommit, commitCount: 1))).detail == "a · 1 commit")
        #expect(activity(.finished(.merged(source: "a", kind: .mergeCommit, commitCount: nil))).detail == "a")
        #expect(activity(.finished(.mergeStopped(source: "a", conflictFileCount: 1))).detail == "conflicts in 1 file")
    }

    @Test func accessibilityTextReadsAsASentence() {
        #expect(
            activity(.finished(.merged(source: "fix/x", kind: .mergeCommit, commitCount: 4))).accessibilityText
                == "Merged fix/x, 4 commits")
        #expect(activity(.finished(.switched(to: "main"))).accessibilityText == "Switched to main")
        #expect(activity(.running(.switchTo("main"))).accessibilityText == "Switching to main")
        #expect(
            activity(.finished(.mergeStopped(source: "fix/x", conflictFileCount: 2))).accessibilityText
                == "Merge stopped, conflicts in 2 files")
    }

    @Test func onlyAMergeKeepsTheNewRemoteBranchBadges() {
        let target = MergeTarget(
            sourceName: "x", sourceRef: "refs/heads/x", sourceTipSha: "s", destinationBranch: "main",
            destinationTipSha: "m")
        #expect(HeadChange.switchTo("a").clearsNewRemoteBranches)
        #expect(HeadChange.create("a").clearsNewRemoteBranches)
        #expect(HeadChange.checkoutTracking(remoteBranch("a")).clearsNewRemoteBranches)
        #expect(!HeadChange.merge(target).clearsNewRemoteBranches)
    }
}
