import Testing

@testable import DiffViewer

/// How the commit picker says how many paths the working tree has changed.
struct ChangeCountTextTests {
    @Test(arguments: [(0, "No changes"), (1, "1 change"), (2, "2 changes"), (120, "120 changes")])
    func changeCountText(count: Int, text: String) {
        #expect(ChangeCountText.make(count) == text)
    }
}
