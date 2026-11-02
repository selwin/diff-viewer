import Foundation
import Testing

@testable import DiffViewer

/// Deriving the title bar's connection and the branch picker's status from one check.
struct GitHubConnectionTests {
    private static let origin = GitHubRepository(owner: "acme", name: "widgets")
    private static let other = GitHubRepository(owner: "acme", name: "gadgets")
    private static let url = URL(string: "https://github.com/acme/widgets")!
    private static let variable = GitHubTokenSource.environment(name: "GH_TOKEN")

    @Test(
        arguments: [
            (
                .anonymous(cli: .missing),
                GitHubCheckOutcome(connection: .cliNotFound(origin), status: .anonymous)
            ),
            (
                .anonymous(cli: .found(version: "2.63.0")),
                GitHubCheckOutcome(
                    connection: .notSignedIn(origin, cliProbe: .found(version: "2.63.0"), rejectedSource: nil),
                    status: .anonymous)
            ),
            (
                .anonymous(cli: .found(version: nil)),
                GitHubCheckOutcome(
                    connection: .notSignedIn(origin, cliProbe: .found(version: nil), rejectedSource: nil),
                    status: .anonymous)
            ),
            (
                .rejected(source: variable),
                GitHubCheckOutcome(
                    connection: .notSignedIn(origin, cliProbe: nil, rejectedSource: variable),
                    status: .rejected(source: variable))
            ),
            (
                .token(source: .gitHubCLI, login: "me", access: .unauthorized),
                GitHubCheckOutcome(
                    connection: .notSignedIn(origin, cliProbe: nil, rejectedSource: .gitHubCLI),
                    status: .rejected(source: .gitHubCLI))
            ),
            (
                .token(source: .gitHubCLI, login: "me", access: .denied),
                GitHubCheckOutcome(
                    connection: .noAccess(origin, login: "me", source: .gitHubCLI),
                    status: .token(source: .gitHubCLI, login: "me"))
            ),
            (
                .token(source: variable, login: nil, access: .found(isPrivate: true, url: url)),
                GitHubCheckOutcome(
                    connection: .connected(origin, login: nil, source: variable, isPrivate: true, url: url),
                    status: .token(source: variable, login: nil))
            ),
            (
                .token(source: .gitHubCLI, login: "me", access: .found(isPrivate: false, url: url)),
                GitHubCheckOutcome(
                    connection: .connected(origin, login: "me", source: .gitHubCLI, isPrivate: false, url: url),
                    status: .token(source: .gitHubCLI, login: "me"))
            ),
        ] as [(GitHubRepositoryCheck, GitHubCheckOutcome)])
    func aCheckDerivesTheConnectionAndStatusTogether(check: GitHubRepositoryCheck, expected: GitHubCheckOutcome) {
        #expect(GitHubCheckOutcome.make(origin: Self.origin, check: check, previous: nil) == expected)
    }

    @Test func aTransientFailureKeepsOnlyTheSameRepositorysPreviousConnection() {
        let transient = GitHubRepositoryCheck.token(source: .gitHubCLI, login: "me", access: .transient)
        let same = GitHubConnection.connected(
            GitHubRepository(owner: "ACME", name: "Widgets"), login: "me", source: .gitHubCLI, isPrivate: false,
            url: Self.url)
        let elsewhere = GitHubConnection.connected(
            Self.other, login: "me", source: .gitHubCLI, isPrivate: false, url: Self.url)

        let kept = GitHubCheckOutcome.make(origin: Self.origin, check: transient, previous: same)
        #expect(kept.connection == same)
        #expect(kept.status == .token(source: .gitHubCLI, login: "me"))
        for previous in [elsewhere, .notOnGitHub, nil] as [GitHubConnection?] {
            let outcome = GitHubCheckOutcome.make(origin: Self.origin, check: transient, previous: previous)
            #expect(outcome.connection == .unreachable(Self.origin))
        }
    }

    @Test(
        arguments: [
            ("gh version 2.63.0 (2024-11-27)\nhttps://github.com/cli/cli/releases/tag/v2.63.0\n", "2.63.0"),
            ("gh version 2.40.1", "2.40.1"),
            ("gh version", nil),
            ("gh version dev", nil),
            ("hub version 2.14.2", nil),
            ("", nil),
        ] as [(String, String?)])
    func theCLIVersionComesFromTheFirstLine(output: String, expected: String?) {
        #expect(GitHubCLIProbe.parseVersion(output) == expected)
    }
}
