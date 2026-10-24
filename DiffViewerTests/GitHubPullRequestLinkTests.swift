import Foundation
import Testing

@testable import DiffViewer

/// GitHub remote validation and the pull request page's URL.
struct GitHubPullRequestLinkTests {
    private static func urls(_ fetch: String, push: [String]? = nil) -> RemoteURLs {
        RemoteURLs(fetchURL: fetch, pushURLs: push ?? [fetch])
    }

    private static func branch(
        remoteRef: String = "refs/heads/feature", remote: String = "origin",
        tracking: UpstreamTracking = .counts(ahead: 0, behind: 0)
    ) -> LocalBranch {
        localBranch(
            "local-name",
            upstream: upstream("\(remote)/feature", remote: remote, remoteRef: remoteRef, tracking: tracking))
    }

    @Test func aRemoteValidatesOnlyWhenEveryPushURLIsItsRepository() {
        // SSH and HTTPS, in any case, name one repository.
        let sameRepository = Self.urls(
            "https://github.com/me/widgets", push: ["git@github.com:ME/Widgets.git", "https://github.com/me/widgets"])
        #expect(
            GitHubRemoteValidation.validate(sameRepository)
                == .repository(GitHubRepository(owner: "me", name: "widgets")))
        let oneElsewhere = Self.urls(
            "https://github.com/me/widgets", push: ["https://github.com/me/widgets", "https://github.com/acme/widgets"])
        #expect(GitHubRemoteValidation.validate(oneElsewhere) == .pushesElsewhere)
    }

    @Test(
        arguments: [
            // `upstream` on the same repository, in another case, isn't a fork.
            (
                "https://github.com/ME/Widgets", urls("https://github.com/me/widgets"), "refs/heads/feature",
                "https://github.com/ME/Widgets/compare/feature?quick_pull=1"
            ),
            // `upstream` on another repository is the base, even with its push disabled.
            (
                "https://github.com/me/gadgets", urls("https://github.com/acme/widgets", push: ["DISABLE"]),
                "refs/heads/feature", "https://github.com/acme/widgets/compare/me:gadgets:feature?quick_pull=1"
            ),
            (
                "https://github.com/me/widgets", urls("https://gitlab.com/acme/widgets"), "refs/heads/feature",
                "https://github.com/me/widgets/compare/feature?quick_pull=1"
            ),
            // Encoded once, keeping the slash.
            (
                "https://github.com/me/widgets", nil, "refs/heads/fix/50%#?é",
                "https://github.com/me/widgets/compare/fix/50%25%23%3F%C3%A9?quick_pull=1"
            ),
        ] as [(String, RemoteURLs?, String, String)])
    func pullRequestURLsNameTheHeadOnlyFromAFork(
        origin: String, upstream: RemoteURLs?, remoteRef: String, expected: String
    ) throws {
        var remotes = ["origin": Self.urls(origin)]
        remotes["upstream"] = upstream
        // Behind is fine: the page shows what was pushed.
        let branch = Self.branch(remoteRef: remoteRef, tracking: .counts(ahead: 0, behind: 3))
        #expect(try GitHubPullRequestLink.make(for: branch, remotes: remotes).get().absoluteString == expected)
    }

    @Test(
        arguments: [
            (localBranch("local-name"), .branchChanged),
            (branch(tracking: .gone), .branchChanged),
            (branch(remoteRef: "refs/tags/v1"), .notABranch),
            (branch(remoteRef: "refs/heads/"), .notABranch),
            (branch(remote: "gone"), .remoteMissing("gone")),
            (branch(remote: "gitlab"), .notOnGitHub("gitlab")),
            (branch(remote: "mirror"), .pushesElsewhere("mirror")),
            (branch(tracking: .counts(ahead: 1, behind: 2)), .unpushed),
        ] as [(LocalBranch, GitHubPullRequestLink.Failure)])
    func branchesWithoutAPushedGitHubBranchFail(branch: LocalBranch, expected: GitHubPullRequestLink.Failure) {
        let remotes = [
            "origin": Self.urls("https://github.com/me/widgets"),
            "gitlab": Self.urls("https://gitlab.com/me/widgets"),
            "mirror": Self.urls("https://github.com/me/widgets", push: ["https://example.com/widgets.git"]),
        ]
        #expect(GitHubPullRequestLink.make(for: branch, remotes: remotes) == .failure(expected))
    }
}
