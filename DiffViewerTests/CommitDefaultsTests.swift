import Foundation
import Testing

@testable import DiffViewer

/// The precedence git itself applies between SQUASH_MSG, MERGE_MSG and commit.template,
/// checked here without touching a repository.
@Suite struct CommitDefaultsTests {
    struct Case: CustomTestStringConvertible {
        let name: String
        let merge: String?
        let squash: String?
        let template: String?
        let text: String?
        let source: CommitDefaults.Suggestion.Source?

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "a merge message alone is the suggestion", merge: "Merge branch 'side'\n", squash: nil,
            template: nil, text: "Merge branch 'side'\n", source: .merge),
        // A squashed merge that also has a MERGE_MSG keeps both, squash first.
        Case(
            name: "squash and merge are joined, squash first", merge: "Merge branch 'side'\n",
            squash: "Squashed commit of the following:\n\n", template: nil,
            text: "Squashed commit of the following:\n\nMerge branch 'side'\n", source: .squash),
        Case(
            name: "a squash message alone is the suggestion", merge: nil,
            squash: "Squashed commit of the following:\n", template: nil,
            text: "Squashed commit of the following:\n", source: .squash),
        // The template is the last resort: any merge metadata outranks it.
        Case(
            name: "the template is used when nothing else exists", merge: nil, squash: nil,
            template: "Subject line\n\n", text: "Subject line\n\n", source: .template),
        Case(
            name: "a merge message outranks the template", merge: "Merge\n", squash: nil,
            template: "Subject line\n\n", text: "Merge\n", source: .merge),
    ]

    @Test(arguments: cases) func messagesFollowGitsPrecedence(_ testCase: Case) {
        let suggestion = CommitDefaults.resolveMessage(
            merge: testCase.merge, squash: testCase.squash, template: testCase.template)
        #expect(suggestion?.text == testCase.text)
        #expect(suggestion?.source == testCase.source)
    }

    @Test func nothingToSuggest() {
        #expect(CommitDefaults.resolveMessage(merge: nil, squash: nil, template: nil) == nil)
        #expect(CommitDefaults.none.suggestion == nil)
        #expect(!CommitDefaults.none.isMerging)
    }
}
