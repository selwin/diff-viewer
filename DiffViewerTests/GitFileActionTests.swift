import Foundation
import Testing

@testable import DiffViewer

struct GitFileActionTests {
    struct Case: CustomTestStringConvertible {
        let name: String
        let action: GitFileAction
        let paths: [String]
        let expected: [String]

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "stage adds the path", action: .stage, paths: ["src/a.swift"],
            expected: ["--literal-pathspecs", "add", "--", "src/a.swift"]),
        // `reset`, not `restore --staged`: the latter cannot resolve HEAD in a repository
        // with no commits, which is exactly where every staged file is a staged add.
        Case(
            name: "unstage resets the index entry", action: .unstage, paths: ["src/a.swift"],
            expected: ["--literal-pathspecs", "reset", "-q", "--", "src/a.swift"]),
        Case(
            name: "discard restores the worktree", action: .discard, paths: ["src/a.swift"],
            expected: ["--literal-pathspecs", "restore", "--", "src/a.swift"]),
        // A batch is one command with every path after `--`, in the order given.
        Case(
            name: "several paths follow the separator in order", action: .stage, paths: ["a.swift", "b.swift"],
            expected: ["--literal-pathspecs", "add", "--", "a.swift", "b.swift"]),
    ]

    @Test(arguments: cases) func actionsBecomeGitArguments(_ testCase: Case) {
        #expect(testCase.action.arguments(for: testCase.paths) == testCase.expected)
    }

    /// A path that looks like a glob or an option must reach git as a plain file name,
    /// however many of them the batch carries.
    @Test func everyActionIsLiteralAndEndsWithTheEscapedPaths() {
        let paths = ["a[1].txt", "--force"]
        for action in [GitFileAction.stage, .unstage, .discard] {
            let arguments = action.arguments(for: paths)
            #expect(arguments.first == "--literal-pathspecs", "\(action)")
            #expect(Array(arguments.suffix(paths.count)) == paths, "\(action): the paths are the tail")
            #expect(
                arguments.dropLast(paths.count).last == "--",
                "\(action): -- must immediately precede the path list")
        }
    }
}
