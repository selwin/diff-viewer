import Foundation
import Testing

@testable import DiffViewer

/// Runs a fake `gh` script found on the command environment's PATH.
struct GitHubCLICommandTests {
    private let identity = PullRequestIdentity(
        remoteName: "origin", remoteBranchName: "remote-feature",
        headRepository: GitHubRepository(owner: "me", name: "widgets"),
        baseRepository: GitHubRepository(owner: "acme", name: "widgets"))

    /// A directory holding `gh` with `body` as its script, unless `body` is nil.
    private func makeDirectory(gh body: String?) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DiffViewerGitHubCLI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let body {
            let script = directory.appendingPathComponent("gh")
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        return directory
    }

    private func client(path directory: URL, timeout: Duration = .seconds(10)) -> GitClient {
        GitClient(
            repoRoot: directory,
            resolveCommandEnvironment: {
                ProcessEnvironment(variables: ["PATH": directory.path], inheritance: .replace)
            },
            gitHubCLITimeout: timeout)
    }

    @Test func lookupAsksForTheHeadBranchOnTheBaseRepository() async throws {
        let directory = try makeDirectory(gh: #"printf '%s\n' "$@" >> args.txt"#)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await client(path: directory).findOpenPullRequest(identity)

        // The script ran in the repository, so that is where it wrote.
        let arguments = try String(contentsOf: directory.appendingPathComponent("args.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.starts(with: ["api", "--hostname", "github.com"]))
        #expect(arguments.contains("repos/acme/widgets/pulls"))
        #expect(arguments.contains("head=me:remote-feature"))
        #expect(arguments.contains("--paginate"))
        #expect(arguments.contains(".[] | select(.head.repo != null) | {number, html_url} | @json"))
    }

    /// A `gh` that logs each repository path it is asked about to `calls.txt`, and prints a
    /// pull request only for `matching` ("owner/name"), if any, and exits 1 for `failing`.
    private func makeSearchingDirectory(matching repository: String?, failing failingRepository: String? = nil) throws
        -> URL
    {
        let pullRequest = #"{"number":4,"html_url":"https://github.com/\#(repository ?? "")/pull/4"}"#
        return try makeDirectory(
            gh: """
                for argument in "$@"; do
                  case "$argument" in
                    repos/*) echo "$argument" >> calls.txt ;;
                  esac
                  if [ "$argument" = "repos/\(repository ?? "none")/pulls" ]; then echo '\(pullRequest)'; fi
                  if [ "$argument" = "repos/\(failingRepository ?? "none")/pulls" ]; then exit 1; fi
                done
                """)
    }

    private func calls(in directory: URL) throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("calls.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    @Test func aPullRequestInTheHeadRepositoryIsFound() async throws {
        let directory = try makeSearchingDirectory(matching: "me/widgets")
        defer { try? FileManager.default.removeItem(at: directory) }

        let found = try await client(path: directory).findOpenPullRequest(identity)

        #expect(found?.number == 4)
        #expect(try calls(in: directory) == ["repos/acme/widgets/pulls", "repos/me/widgets/pulls"])
    }

    @Test func noPullRequestInEitherRepositoryFindsNone() async throws {
        let directory = try makeSearchingDirectory(matching: nil)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await client(path: directory).findOpenPullRequest(identity) == nil)
        #expect(try calls(in: directory) == ["repos/acme/widgets/pulls", "repos/me/widgets/pulls"])
    }

    @Test func aRepositoryThatIsBothBaseAndHeadIsSearchedOnce() async throws {
        let directory = try makeSearchingDirectory(matching: nil)
        defer { try? FileManager.default.removeItem(at: directory) }
        let own = GitHubRepository(owner: "me", name: "widgets")
        let ownIdentity = PullRequestIdentity(
            remoteName: "origin", remoteBranchName: "remote-feature", headRepository: own, baseRepository: own)

        _ = try await client(path: directory).findOpenPullRequest(ownIdentity)

        #expect(try calls(in: directory) == ["repos/me/widgets/pulls"])
    }

    @Test func aFailingBaseRepositoryDoesNotStopTheHeadRepositorySearch() async throws {
        let directory = try makeSearchingDirectory(matching: "me/widgets", failing: "acme/widgets")
        defer { try? FileManager.default.removeItem(at: directory) }

        let found = try await client(path: directory).findOpenPullRequest(identity)

        #expect(found?.number == 4)
        #expect(try calls(in: directory) == ["repos/acme/widgets/pulls", "repos/me/widgets/pulls"])
    }

    @Test func aFailureWithNoPullRequestFoundIsThrownNotReportedAsNone() async throws {
        let directory = try makeSearchingDirectory(matching: nil, failing: "acme/widgets")
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: GitHubCLIError.exited(status: 1)) {
            try await client(path: directory).findOpenPullRequest(identity)
        }
    }

    @Test func aPullRequestInTheBaseRepositoryEndsTheSearch() async throws {
        let directory = try makeSearchingDirectory(matching: "acme/widgets")
        defer { try? FileManager.default.removeItem(at: directory) }

        let found = try await client(path: directory).findOpenPullRequest(identity)

        #expect(found?.number == 4)
        #expect(try calls(in: directory) == ["repos/acme/widgets/pulls"])
    }

    @Test func aSuccessfulRunWithNoOutputFindsNoPullRequest() async throws {
        let directory = try makeDirectory(gh: "exit 0")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await client(path: directory).findOpenPullRequest(identity) == nil)
    }

    @Test func failuresToRunGitHubCLIAreReported() async throws {
        let failing = try makeDirectory(gh: "exit 1")
        defer { try? FileManager.default.removeItem(at: failing) }
        await #expect(throws: GitHubCLIError.exited(status: 1)) {
            try await client(path: failing).findOpenPullRequest(identity)
        }

        let missing = try makeDirectory(gh: nil)
        defer { try? FileManager.default.removeItem(at: missing) }
        await #expect(throws: GitHubCLIError.notInstalled) {
            try await client(path: missing).findOpenPullRequest(identity)
        }
        #expect(try await client(path: missing).gitHubCLIStatus() == .notInstalled)
    }

    @Test func theDeadlineEndsASlowRun() async throws {
        let slow = try makeDirectory(gh: "echo '{\"hosts\":{}}'\nexec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: slow) }
        let elapsed = try await ContinuousClock().measure {
            await #expect(throws: GitHubCLIError.timedOut) {
                try await client(path: slow, timeout: .seconds(2)).gitHubCLIStatus()
            }
        }
        #expect(elapsed < .seconds(8), "\(elapsed)")
    }

    @Test func theDeadlineLeavesAFastRunAlone() async throws {
        let fast = try makeDirectory(
            gh: #"echo '{"hosts":{"github.com":[{"state":"success","active":true,"login":"selwin"}]}}'"#)
        defer { try? FileManager.default.removeItem(at: fast) }
        #expect(try await client(path: fast, timeout: .seconds(2)).gitHubCLIStatus() == .signedIn(login: "selwin"))
    }
}
