import Testing

@testable import DiffViewer

/// When the app's fetch may prune: only when nothing but remote-tracking refs can go.
struct FetchRefspecsTests {
    /// Any namespace under `refs/remotes/` prunes; a tag or mirror mapping stops it. A
    /// negative or destination-less refspec stores nothing, so it neither allows nor stops a
    /// prune; with nothing else, there is nothing to prune.
    @Test(
        arguments: [
            (["+refs/heads/*:refs/remotes/origin/*"], true),
            (["+refs/heads/*:refs/remotes/company/*"], true),
            (["+refs/heads/*:refs/remotes/origin/*", "refs/heads/main:refs/remotes/mirror/main"], true),
            (["+refs/heads/*:refs/remotes/origin/*", "refs/tags/*:refs/tags/*"], false),
            (["+refs/*:refs/*"], false),
            ([], false),
            (["^refs/heads/wip/*"], false),
            (["refs/heads/main", "refs/heads/main:"], false),
            (["+refs/heads/*:refs/remotes/origin/*", "^refs/heads/wip/*", "refs/heads/main"], true),
        ] as [([String], Bool)])
    func prunesOnlyWhenEveryDestinationIsATrackingRef(refspecs: [String], prunes: Bool) {
        #expect(FetchRefspecs.prunesOnlyTrackingRefs(refspecs) == prunes)
    }
}

/// Reading a tracking ref back to the remote and source ref that fetch stores into it.
struct FetchRefspecSourcesTests {
    private func sources(_ ref: String, _ refspecs: [String: [String]]) -> Set<FetchRefspecs.Source> {
        FetchRefspecs.sources(of: ref, refspecsByRemote: refspecs)
    }

    private func source(_ remote: String, _ ref: String) -> FetchRefspecs.Source {
        FetchRefspecs.Source(remote: remote, ref: ref)
    }

    @Test func theDefaultGlob() {
        let refspecs = ["origin": ["+refs/heads/*:refs/remotes/origin/*"]]
        #expect(sources("refs/remotes/origin/feature/x", refspecs) == [source("origin", "refs/heads/feature/x")])
        #expect(sources("refs/remotes/other/main", refspecs).isEmpty)
    }

    @Test func aCustomDestinationKeepsItsRemote() {
        let refspecs = ["origin": ["+refs/heads/*:refs/remotes/company/*"]]
        #expect(sources("refs/remotes/company/main", refspecs) == [source("origin", "refs/heads/main")])
    }

    /// The `*` may sit mid-pattern on either side; what it captures moves across.
    @Test func aMidPatternGlob() {
        let refspecs = ["origin": ["refs/heads/feat-*-v2:refs/remotes/origin/v2/*-feat"]]
        #expect(
            sources("refs/remotes/origin/v2/login-feat", refspecs) == [source("origin", "refs/heads/feat-login-v2")])
        #expect(sources("refs/remotes/origin/v2/login", refspecs).isEmpty)
    }

    @Test func anExactRefspec() {
        let refspecs = ["origin": ["refs/heads/main:refs/remotes/mirror/trunk"]]
        #expect(sources("refs/remotes/mirror/trunk", refspecs) == [source("origin", "refs/heads/main")])
        #expect(sources("refs/remotes/mirror/main", refspecs).isEmpty)
    }

    @Test func aNegativeRefspecExcludesItsSources() {
        let refspecs = ["origin": ["+refs/heads/*:refs/remotes/origin/*", "^refs/heads/wip/*"]]
        #expect(sources("refs/remotes/origin/wip/x", refspecs).isEmpty)
        #expect(sources("refs/remotes/origin/feature", refspecs) == [source("origin", "refs/heads/feature")])
    }

    @Test func overlappingRemotesAreBothReported() {
        let refspecs = [
            "team": ["+refs/heads/*:refs/remotes/team/*"],
            "team/a": ["+refs/heads/*:refs/remotes/team/a/*"],
        ]
        #expect(
            sources("refs/remotes/team/a/x", refspecs) == [
                source("team", "refs/heads/a/x"), source("team/a", "refs/heads/x"),
            ])
    }

    @Test func aNonBranchSourceIsReportedAsIs() {
        let refspecs = ["origin": ["+refs/pull/*/head:refs/remotes/origin/pr/*"]]
        #expect(sources("refs/remotes/origin/pr/12", refspecs) == [source("origin", "refs/pull/12/head")])
    }

    /// Destination-less refspecs store nothing, and a glob on one side only is not valid.
    @Test func refspecsThatStoreNothingMapNothing() {
        let refspecs = ["origin": ["refs/heads/main", "refs/heads/main:", "refs/heads/*:refs/remotes/origin/main"]]
        #expect(sources("refs/remotes/origin/main", refspecs).isEmpty)
    }

    /// Config keys keep the remote's case, dots and slashes; a key with no value is skipped.
    @Test func configRecordsAreGroupedByRemote() {
        let output =
            [
                "remote.origin.fetch\n+refs/heads/*:refs/remotes/origin/*",
                "remote.Team/A.v2.fetch\n+refs/heads/*:refs/remotes/Team/A.v2/*",
                "remote.bare.fetch",
                "remote.origin.fetch\n^refs/heads/wip/*",
            ].joined(separator: "\0") + "\0"
        #expect(
            GitClient.parseFetchRefspecs(output) == [
                "origin": ["+refs/heads/*:refs/remotes/origin/*", "^refs/heads/wip/*"],
                "Team/A.v2": ["+refs/heads/*:refs/remotes/Team/A.v2/*"],
            ])
    }
}
