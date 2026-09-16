import Foundation
import Testing

@testable import DiffViewer

/// The precedence git itself applies between SQUASH_MSG, MERGE_MSG and commit.template,
/// checked here without touching a repository.
@Suite struct CommitDefaultsTests {
    @Test func mergeMessageAloneIsTheSuggestion() {
        let suggestion = CommitDefaults.resolveMessage(merge: "Merge branch 'side'\n", squash: nil, template: nil)
        #expect(suggestion?.text == "Merge branch 'side'\n")
        #expect(suggestion?.source == .merge)
    }

    /// A squashed merge that also has a MERGE_MSG keeps both, squash first.
    @Test func squashAndMergeAreJoinedSquashFirst() {
        let suggestion = CommitDefaults.resolveMessage(
            merge: "Merge branch 'side'\n", squash: "Squashed commit of the following:\n\n", template: nil)
        #expect(suggestion?.text == "Squashed commit of the following:\n\nMerge branch 'side'\n")
        #expect(suggestion?.source == .squash)
    }

    @Test func squashMessageAloneIsTheSuggestion() {
        let suggestion = CommitDefaults.resolveMessage(
            merge: nil, squash: "Squashed commit of the following:\n", template: nil)
        #expect(suggestion?.text == "Squashed commit of the following:\n")
        #expect(suggestion?.source == .squash)
    }

    /// The template is the last resort: any merge metadata outranks it.
    @Test func templateIsUsedOnlyWhenNothingElseExists() {
        let suggestion = CommitDefaults.resolveMessage(merge: nil, squash: nil, template: "Subject line\n\n")
        #expect(suggestion?.text == "Subject line\n\n")
        #expect(suggestion?.source == .template)

        let withMerge = CommitDefaults.resolveMessage(merge: "Merge\n", squash: nil, template: "Subject line\n\n")
        #expect(withMerge?.source == .merge)
    }

    @Test func nothingToSuggest() {
        #expect(CommitDefaults.resolveMessage(merge: nil, squash: nil, template: nil) == nil)
        #expect(CommitDefaults.none.suggestion == nil)
        #expect(!CommitDefaults.none.isMerging)
    }
}
