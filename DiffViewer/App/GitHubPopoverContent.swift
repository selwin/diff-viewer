import Foundation

/// What the popover says and offers for one connection state.
struct GitHubPopoverContent: Equatable {
    enum Glyph: Equatable {
        case progress, connected, warning, offline
    }

    enum Action: Equatable {
        case openOnGitHub(URL)
        case checkAgain
        case openTerminal

        var title: String {
            switch self {
            case .openOnGitHub: "Open on GitHub"
            case .checkAgain: "Check Again"
            case .openTerminal: "Open Terminal"
            }
        }
    }

    struct Command: Equatable {
        let text: String
        var hint: String?
    }

    var glyph: Glyph
    var title: String
    /// The card's wrapping text, one paragraph per line.
    var lines: [String] = []
    var commands: [Command] = []
    var linksToInstallGuide = false
    var actions: [Action] = []

    private static let signIn = Command(text: "gh auth login --hostname github.com")

    /// Open Terminal leads when offered; Check Again does when it is the only way forward.
    func isPrimary(_ action: Action) -> Bool {
        switch action {
        case .openTerminal: true
        case .checkAgain: actions.count == 1
        case .openOnGitHub: false
        }
    }

    /// A check that runs long shows Checking, whether or not an older result is known.
    static func make(connection: GitHubConnection?, showsProgress: Bool) -> GitHubPopoverContent {
        guard !showsProgress, let connection else {
            return GitHubPopoverContent(
                glyph: .progress, title: "Checking…", lines: ["Asking GitHub about this repository"])
        }
        switch connection {
        case let .connected(_, login, source, _, url):
            let name = GitHubTokenSourceText.name(source)
            let line = login.map { "Signed in as @\($0) via \(name)" } ?? "Authenticated via \(name)"
            return GitHubPopoverContent(
                glyph: .connected, title: "Connected", lines: [line], actions: [.openOnGitHub(url)])
        case .cliNotFound:
            return notFound
        case let .notSignedIn(_, cliProbe, rejectedSource):
            return notSignedIn(cliProbe: cliProbe, rejectedSource: rejectedSource)
        case let .noAccess(_, login, source):
            return noAccess(login: login, source: source)
        case .unreachable:
            return GitHubPopoverContent(glyph: .offline, title: "Couldn't reach GitHub", actions: [.checkAgain])
        case .notOnGitHub:
            return GitHubPopoverContent(
                glyph: .warning, title: "Not on GitHub", lines: ["This repository's origin isn't on github.com."])
        }
    }

    private static var notFound: GitHubPopoverContent {
        GitHubPopoverContent(
            glyph: .warning, title: "GitHub CLI not found", lines: ["Install gh to connect this repository."],
            commands: [Command(text: "brew install gh")], linksToInstallGuide: true, actions: [.openTerminal])
    }

    private static func notSignedIn(
        cliProbe: GitHubCLIProbe?, rejectedSource: GitHubTokenSource?
    ) -> GitHubPopoverContent {
        switch (rejectedSource, cliProbe) {
        case let (.environment(name)?, _):
            return GitHubPopoverContent(
                glyph: .warning, title: "Token rejected",
                lines: ["GitHub rejected the token in \(name). Replace or unset it."], actions: [.checkAgain])
        case (.gitHubCLI?, _):
            return GitHubPopoverContent(
                glyph: .warning, title: "Not signed in", lines: ["GitHub rejected the GitHub CLI's token."],
                commands: [signIn], actions: [.openTerminal])
        case (nil, .missing?):
            return notFound
        case let (nil, .found(version)?):
            let line =
                version.map { "gh \($0) is installed but has no GitHub account." }
                ?? "The GitHub CLI is installed but has no GitHub account."
            return GitHubPopoverContent(
                glyph: .warning, title: "Not signed in", lines: [line], commands: [signIn], actions: [.openTerminal])
        case (nil, nil):
            return GitHubPopoverContent(
                glyph: .warning, title: "Not signed in", lines: ["No GitHub account is signed in."],
                commands: [signIn], actions: [.openTerminal])
        }
    }

    private static func noAccess(login: String?, source: GitHubTokenSource) -> GitHubPopoverContent {
        var lines = [
            "The current credentials can't access this repository. Check the repository URL and token permissions."
        ]
        if let login { lines.append("Signed in as @\(login)") }
        switch source {
        case .gitHubCLI:
            let switchAccount = Command(
                text: "gh auth switch --hostname github.com",
                hint: "or `gh auth login --hostname github.com` to add an account")
            return GitHubPopoverContent(
                glyph: .warning, title: "No access", lines: lines, commands: [switchAccount],
                actions: [.openTerminal, .checkAgain])
        case let .environment(name):
            lines.append("\(name) takes precedence over the GitHub CLI. Replace or unset it to use another account.")
            return GitHubPopoverContent(glyph: .warning, title: "No access", lines: lines, actions: [.checkAgain])
        }
    }
}
