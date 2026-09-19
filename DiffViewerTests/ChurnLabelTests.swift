import Testing

@testable import DiffViewer

/// `ChurnLabel.isEmpty(for:)` says when the label draws nothing, which decides whether
/// a header rail needs a divider before it.
struct ChurnLabelTests {
    @Test func nothingToShowIsEmpty() {
        #expect(ChurnLabel.isEmpty(for: nil))
        #expect(ChurnLabel.isEmpty(for: .counted(added: 0, deleted: 0)))
    }

    @Test func anyCountOrABinaryShowsSomething() {
        #expect(!ChurnLabel.isEmpty(for: .counted(added: 3, deleted: 0)))
        #expect(!ChurnLabel.isEmpty(for: .counted(added: 0, deleted: 2)))
        #expect(!ChurnLabel.isEmpty(for: .binary(nil)))
    }
}
