import Testing

@testable import DiffViewer

struct ShortstatParserTests {
    @Test(
        arguments: [
            (" 3 files changed, 10 insertions(+), 4 deletions(-)\n", 3, 10, 4),
            (" 1 file changed, 1 insertion(+), 1 deletion(-)\n", 1, 1, 1),
            (" 2 files changed, 7 insertions(+)\n", 2, 7, 0),
            (" 2 files changed, 5 deletions(-)\n", 2, 0, 5),
            (" 1 file changed, 0 insertions(+), 0 deletions(-)\n", 1, 0, 0),
            ("", 0, 0, 0),
            ("\n", 0, 0, 0),
        ] as [(String, Int, Int, Int)])
    func readsEveryForm(output: String, files: Int, added: Int, deleted: Int) throws {
        let summary = try ShortstatParser.parse(output)
        #expect(summary == IncomingChangeSummary(fileCount: files, addedLineCount: added, deletedLineCount: deleted))
    }

    @Test(
        arguments: [
            "fatal: bad revision",
            " 3 files changed, 10 insertions",
            " 1 file changed, 1 insertion(+) extra",
            "x files changed",
            " 1 file changed, 999999999999999999999999 insertions(+)",
            " 1 file changed, 999999999999999999999999 deletions(-)",
        ])
    func malformedOutputThrows(output: String) {
        #expect(throws: ShortstatParseError.self) { try ShortstatParser.parse(output) }
    }
}
