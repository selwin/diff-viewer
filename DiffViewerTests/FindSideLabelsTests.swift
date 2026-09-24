import AppKit
import Testing

@testable import DiffViewer

struct FindSideLabelsTests {
    @Test func namedBranchLabelsHeadAndWorkingTree() {
        let labels = FindSideLabels.make(scope: .workingTree, headState: .named("main"))
        #expect(labels.old == FindSideLabel(title: "main", icon: .branch))
        #expect(labels.new == FindSideLabel(title: "Working Tree", icon: .workingTree))
    }

    @Test func detachedHeadShowsTheShortSha() {
        let labels = FindSideLabels.make(scope: .workingTree, headState: .detached(sha: "0123456789abcdef"))
        #expect(labels.old == FindSideLabel(title: "0123456", icon: .commit))
        #expect(labels.new.title == "Working Tree")
    }

    @Test func unreadHeadIsNotShownAsDetached() {
        let labels = FindSideLabels.make(scope: .workingTree, headState: nil)
        #expect(labels.old == FindSideLabel(title: "HEAD", icon: nil))
    }

    @Test func commitScopeIgnoresHead() {
        let commit = CommitRef(sha: objectID("c"), shortSha: "c000000", firstParentSHA: objectID("p"))
        let labels = FindSideLabels.make(scope: .commit(commit), headState: .named("main"))
        #expect(labels.old == FindSideLabel(title: "Before", icon: nil))
        #expect(labels.new == FindSideLabel(title: "After", icon: nil))
    }
}

@MainActor
struct FindScopeTruncationTests {
    private let font = NSFont.systemFont(ofSize: 11)

    private func width(_ string: String) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: font]).size().width
    }

    @Test func shortNamesAreUntouched() {
        #expect(FindScopeControl.truncatingMiddle("main", toFit: 100, font: font) == "main")
    }

    @Test func longNameFitsAndKeepsHeadAndTail() {
        let name = "feature/very-long-branch-name-for-the-find-scope-control-JIRA-1234"
        let result = FindScopeControl.truncatingMiddle(name, toFit: 120, font: font)
        #expect(width(result) <= 120)
        #expect(result.contains("…"))
        let parts = result.split(separator: "…", omittingEmptySubsequences: false)
        #expect(parts.count == 2)
        #expect(name.hasPrefix(parts[0]) && !parts[0].isEmpty)
        #expect(name.hasSuffix(parts[1]) && !parts[1].isEmpty)
    }

    @Test func segmentTextCountsAndSingular() {
        #expect(FindScopeSegmentText(name: "main", count: nil, hasQuery: false).countText == nil)
        #expect(FindScopeSegmentText(name: "main", count: nil, hasQuery: true).countText == "–")
        let one = FindScopeSegmentText(name: "main", count: 1, hasQuery: true)
        #expect(one.toolTip == "main · 1 match")
        #expect(FindScopeSegmentText(name: "main", count: 4, hasQuery: true).accessibilityLabel == "main, 4 matches")
    }
}
