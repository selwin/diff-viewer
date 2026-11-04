import Testing

@testable import DiffViewer

struct AuthorNameTests {
    @Test(arguments: [
        ("Andra Antariksa", "Andra"), ("robbieadi", "robbieadi"), ("dependabot[bot]", "dependabot[bot]"),
        ("  Selwin Ong  ", "Selwin"), ("Selwin\tOng", "Selwin"), ("\nSelwin\nOng", "Selwin"), ("   ", ""), ("", ""),
    ])
    func firstTokenIsTheFirstWhitespaceSeparatedWord(author: String, expected: String) {
        #expect(AuthorName.firstToken(of: author) == expected)
    }
}
