import Foundation
import Testing

@testable import DiffViewer

struct GitFileActionTests {
    @Test func stageAddsThePath() {
        #expect(
            GitFileAction.stage.arguments(for: "src/a.swift") == ["--literal-pathspecs", "add", "--", "src/a.swift"])
    }

    /// `reset`, not `restore --staged`: the latter cannot resolve HEAD in a repository
    /// with no commits, which is exactly where every staged file is a staged add.
    @Test func unstageResetsTheIndexEntry() {
        #expect(
            GitFileAction.unstage.arguments(for: "src/a.swift")
                == ["--literal-pathspecs", "reset", "-q", "--", "src/a.swift"])
    }

    @Test func discardRestoresTheWorktree() {
        #expect(
            GitFileAction.discard.arguments(for: "src/a.swift")
                == ["--literal-pathspecs", "restore", "--", "src/a.swift"])
    }

    /// A path that looks like a glob or an option must reach git as a plain file name.
    @Test func everyActionIsLiteralAndEndsWithAnEscapedPath() {
        for action in [GitFileAction.stage, .unstage, .discard] {
            let arguments = action.arguments(for: "a[1].txt")
            #expect(arguments.first == "--literal-pathspecs", "\(action)")
            #expect(arguments.last == "a[1].txt", "\(action)")
            #expect(arguments.dropLast().last == "--", "\(action): -- must immediately precede the path")
        }
    }
}
