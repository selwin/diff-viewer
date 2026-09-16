import Foundation
import Testing

@testable import DiffViewer

struct GitFileActionTests {
    @Test func stageAddsThePath() {
        #expect(
            GitFileAction.stage.arguments(for: ["src/a.swift"]) == ["--literal-pathspecs", "add", "--", "src/a.swift"])
    }

    /// `reset`, not `restore --staged`: the latter cannot resolve HEAD in a repository
    /// with no commits, which is exactly where every staged file is a staged add.
    @Test func unstageResetsTheIndexEntry() {
        #expect(
            GitFileAction.unstage.arguments(for: ["src/a.swift"])
                == ["--literal-pathspecs", "reset", "-q", "--", "src/a.swift"])
    }

    @Test func discardRestoresTheWorktree() {
        #expect(
            GitFileAction.discard.arguments(for: ["src/a.swift"])
                == ["--literal-pathspecs", "restore", "--", "src/a.swift"])
    }

    /// A batch is one command with every path after `--`, in the order given.
    @Test func severalPathsFollowTheSeparatorInOrder() {
        #expect(
            GitFileAction.stage.arguments(for: ["a.swift", "b.swift"])
                == ["--literal-pathspecs", "add", "--", "a.swift", "b.swift"])
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
