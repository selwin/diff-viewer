import Foundation

/// How a credential source is named in sentences. Only the name: the branch picker and the
/// GitHub popover each word the rest.
enum GitHubTokenSourceText {
    static func name(_ source: GitHubTokenSource) -> String {
        switch source {
        case let .environment(name): name
        case .gitHubCLI: "the GitHub CLI"
        }
    }
}
