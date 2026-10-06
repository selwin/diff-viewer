import Testing

@testable import DiffViewer

struct BranchNameProposalTests {
    @Test(arguments: [
        (raw: "feature name", proposal: String?.some("feature-name")),
        (raw: "  a \t b ", proposal: "a-b"),
        (raw: "", proposal: nil),
        (raw: " \t ", proposal: nil),
    ])
    func whitespaceRunsBecomeHyphens(raw: String, proposal: String?) {
        #expect(BranchNameProposal.make(from: raw) == proposal)
    }
}
