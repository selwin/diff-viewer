import Foundation

extension DebugLaunchOptions {
    /// Forces the window's GitHub connection into the `DIFFVIEWER_GITHUB_STATE` state, if it
    /// names one, then opens the GitHub popover when asked. An unknown value is ignored.
    @MainActor
    static func applyGitHub(state: String, popover: Bool, in windowState: WindowState) {
        #if DEBUG
            if let model = windowState.gitHubConnectionModel {
                let origin: GitHubRepository
                if case let .repository(real) = model.origin {
                    origin = real
                } else {
                    origin = GitHubRepository(owner: "selwin", name: "diff-viewer")
                }
                forceGitHubState(state, origin: origin, on: model)
            }
            windowState.isGitHubPopoverPresented = popover
        #endif
    }

    #if DEBUG
        @MainActor
        private static func forceGitHubState(
            _ state: String, origin: GitHubRepository, on model: GitHubConnectionModel
        ) {
            let cli = GitHubTokenSource.gitHubCLI
            let environment = GitHubTokenSource.environment(name: "GH_TOKEN")
            let url = URL(string: "https://github.com/\(origin.fullName)")
            let connection: GitHubConnection?
            switch state {
            case "connected":
                connection = url.map { .connected(origin, login: "selwin", source: cli, isPrivate: false, url: $0) }
            case "connected-no-login":
                connection = url.map { .connected(origin, login: nil, source: environment, isPrivate: true, url: $0) }
            case "checking": connection = nil
            case "cli-missing": connection = .cliNotFound(origin)
            case "signed-out":
                connection = .notSignedIn(origin, cliProbe: .found(version: "2.63.0"), rejectedSource: nil)
            case "env-rejected": connection = .notSignedIn(origin, cliProbe: nil, rejectedSource: environment)
            case "no-access": connection = .noAccess(origin, login: "selwin", source: cli)
            case "no-access-env": connection = .noAccess(origin, login: nil, source: environment)
            case "unreachable": connection = .unreachable(origin)
            case "not-github":
                model.forceState(origin: .none, connection: .notOnGitHub, showsProgress: false)
                return
            default: return
            }
            model.forceState(origin: .repository(origin), connection: connection, showsProgress: state == "checking")
        }
    #endif
}
