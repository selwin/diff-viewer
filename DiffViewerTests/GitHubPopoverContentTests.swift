import Foundation
import Testing

@testable import DiffViewer

private let repository = GitHubRepository(owner: "acme", name: "widgets")
private let url = URL(string: "https://github.com/acme/widgets")!

/// What the GitHub popover says and offers: recovery that fits the credential source, the
/// variable named as it is, and fallbacks for what GitHub or gh didn't say.
struct GitHubPopoverContentTests {
    @Test func noAccessRecoveryFitsTheCredentialSource() {
        let cli = GitHubPopoverContent.make(
            connection: .noAccess(repository, login: "me", source: .gitHubCLI), showsProgress: false)
        #expect(cli.commands.map(\.text) == ["gh auth switch --hostname github.com"])
        #expect(cli.actions == [.openTerminal, .checkAgain])

        // gh can't switch away from a variable that takes precedence, so no command is offered.
        let environment = GitHubPopoverContent.make(
            connection: .noAccess(repository, login: nil, source: .environment(name: "GITHUB_TOKEN")),
            showsProgress: false)
        #expect(environment.commands.isEmpty)
        #expect(environment.actions == [.checkAgain])
        #expect(environment.lines.contains { $0.hasPrefix("GITHUB_TOKEN takes precedence") })
    }

    @Test(
        arguments: [
            (
                GitHubConnection.notSignedIn(
                    repository, cliProbe: nil, rejectedSource: .environment(name: "GITHUB_TOKEN")),
                "GitHub rejected the token in GITHUB_TOKEN. Replace or unset it."
            ),
            (
                .connected(
                    repository, login: nil, source: .environment(name: "GITHUB_TOKEN"), isPrivate: false, url: url),
                "Authenticated via GITHUB_TOKEN"
            ),
            (
                .connected(repository, login: "me", source: .gitHubCLI, isPrivate: false, url: url),
                "Signed in as @me via the GitHub CLI"
            ),
            (
                .notSignedIn(repository, cliProbe: .found(version: "2.63.0"), rejectedSource: nil),
                "gh 2.63.0 is installed but has no GitHub account."
            ),
            (
                .notSignedIn(repository, cliProbe: .found(version: nil), rejectedSource: nil),
                "The GitHub CLI is installed but has no GitHub account."
            ),
        ] as [(GitHubConnection, String)])
    func theCardNamesWhatIsKnown(connection: GitHubConnection, line: String) {
        #expect(GitHubPopoverContent.make(connection: connection, showsProgress: false).lines.first == line)
    }

    @Test func progressHidesThePreviousStatesCommandsAndActions() {
        let content = GitHubPopoverContent.make(connection: .cliNotFound(repository), showsProgress: true)
        #expect(content.title == "Checking…")
        #expect(content.commands.isEmpty)
        #expect(content.actions.isEmpty)
        #expect(!content.linksToInstallGuide)
    }
}
