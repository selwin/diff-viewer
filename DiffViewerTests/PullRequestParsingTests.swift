import Testing

@testable import DiffViewer

struct PullRequestParsingTests {
    private let acme = GitHubRepository(owner: "acme", name: "widgets")

    @Test(
        arguments: [
            ("https://github.com/acme/widgets", "acme/widgets"),
            ("https://github.com/acme/widgets.git", "acme/widgets"),
            ("https://GitHub.com/acme/widgets/", "acme/widgets"),
            ("git@github.com:acme/widgets", "acme/widgets"),
            ("git@github.com:acme/widgets.git", "acme/widgets"),
            ("ssh://git@github.com/acme/widgets", "acme/widgets"),
            ("ssh://git@github.com/acme/widgets.git", "acme/widgets"),
            ("https://gitlab.com/acme/widgets.git", nil),
            ("git@gitlab.com:acme/widgets.git", nil),
            ("https://github.com/acme", nil),
            ("/Users/me/code/widgets", nil),
        ] as [(String, String?)])
    func remoteURLsNameARepositoryOnlyOnGitHub(url: String, expected: String?) {
        #expect(GitHubRepository.parse(remoteURL: url)?.fullName == expected)
    }

    @Test(
        arguments: [
            (
                "https://github.com/acme/widgets/pull/61",
                PullRequestInput.url(.init(owner: "acme", name: "widgets"), 61)
            ),
            ("  https://github.com/acme/widgets/pull/61\n", .url(.init(owner: "acme", name: "widgets"), 61)),
            ("https://github.com/acme/widgets/pull/61/files", .url(.init(owner: "acme", name: "widgets"), 61)),
            ("https://github.com/acme/widgets/pull/61/commits/abc123", .url(.init(owner: "acme", name: "widgets"), 61)),
            ("https://github.com/acme/widgets/pull/61?diff=split", .url(.init(owner: "acme", name: "widgets"), 61)),
            ("https://github.com/acme/widgets/pull/61#discussion_r1", .url(.init(owner: "acme", name: "widgets"), 61)),
            ("#61", .number(61)),
            (" #7 ", .number(7)),
        ] as [(String, PullRequestInput)])
    func pullRequestLinksAndNumbersParse(text: String, expected: PullRequestInput) {
        #expect(PullRequestInput.parse(text) == expected)
    }

    @Test(arguments: [
        "https://github.com/acme/widgets/issues/5",
        "https://github.com/acme/widgets/pull/abc",
        "https://github.com/acme/widgets/pull/0",
        "https://github.com/acme/widgets/pull/+5",
        "https://github.com/acme/widgets/pull",
        "https://github.com/acme/pull/5",
        "https://gitlab.com/acme/widgets/pull/5",
        "http://github.com/acme/widgets/pull/61",
        "https://github.com/acme//widgets/pull/61",
        "#", "#0", "#abc", "61", "", "not a link",
    ])
    func otherInputIsRejected(text: String) {
        #expect(PullRequestInput.parse(text) == nil)
    }

    private func remote(_ name: String, _ url: String) -> GitRemote { GitRemote(name: name, fetchURL: url) }

    private func chosen(_ input: PullRequestInput, from remotes: [GitRemote]) -> String? {
        try? PullRequestRemote.choose(for: input, remotes: remotes).name
    }

    @Test(arguments: [
        PullRequestInput.url(.init(owner: "acme", name: "widgets"), 1),
        .url(.init(owner: "ACME", name: "Widgets"), 1),
    ])
    func aLinkPicksOnlyTheRemoteOnItsRepositoryIgnoringCase(input: PullRequestInput) {
        let remotes = [
            remote("fork", "https://github.com/me/widgets.git"),
            remote("origin", "git@github.com:acme/widgets.git"),
            remote("mirror", "https://gitlab.com/acme/widgets.git"),
        ]
        #expect(chosen(input, from: remotes) == "origin")
    }

    @Test(arguments: [PullRequestInput.url(.init(owner: "acme", name: "widgets"), 1), .number(1)])
    func severalMatchesGoUpstreamThenOriginThenByName(input: PullRequestInput) {
        let url = "https://github.com/acme/widgets.git"
        let all = [remote("zed", url), remote("origin", url), remote("alpha", url), remote("upstream", url)]
        #expect(chosen(input, from: all) == "upstream")
        #expect(chosen(input, from: all.filter { $0.name != "upstream" }) == "origin")
        #expect(chosen(input, from: all.filter { $0.name == "zed" || $0.name == "alpha" }) == "alpha")
    }

    @Test func aNumberAcceptsAnyGitHubRemoteAndSkipsTheRest() {
        let remotes = [
            remote("backup", "https://gitlab.com/me/widgets.git"),
            remote("zed", "https://github.com/me/widgets.git"),
        ]
        #expect(chosen(.number(3), from: remotes) == "zed")
    }

    @Test func refusesWhatNoRemoteCanServe() {
        let remotes = [remote("origin", "https://github.com/me/widgets.git")]
        #expect(throws: PullRequestRemoteError.notARemote(acme)) {
            try PullRequestRemote.choose(for: .url(acme, 1), remotes: remotes)
        }
        let elsewhere = [remote("origin", "https://gitlab.com/acme/widgets.git")]
        #expect(throws: PullRequestRemoteError.noGitHubRemote) {
            try PullRequestRemote.choose(for: .url(acme, 1), remotes: elsewhere)
        }
        #expect(throws: PullRequestRemoteError.noGitHubRemote) {
            try PullRequestRemote.choose(for: .number(1), remotes: [])
        }
    }
}
