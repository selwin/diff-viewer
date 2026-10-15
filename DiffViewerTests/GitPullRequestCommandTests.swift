import Foundation
import Testing

@testable import DiffViewer

/// Runs the real `git` against a bare remote that serves pull request refs.
@Suite(.serialized) struct GitPullRequestCommandTests {
    typealias Repo = GitCommandTests.Repo

    /// A bare remote whose HEAD is `main`, the repository that publishes to it, and a clone
    /// that does the fetching. All three hold the root commit.
    private final class Fixture {
        let bare: Repo
        let publisher: Repo
        let clone: Repo
        let root: String

        init() async throws {
            bare = try Repo()
            try await bare.git(["init", "--bare", "-b", "main"])
            publisher = try await committedRepo(["a.txt": "one\n"])
            root = try await publisher.git(["rev-parse", "HEAD"])
            try await publisher.git(["remote", "add", "origin", bare.url.path])
            try await publisher.git(["push", "origin", "main"])
            clone = try Repo()
            try await clone.git(["clone", bare.url.path, "."])
            try await clone.prepareForCommits()
        }

        var client: GitClient { clone.client }
        var prefix: String { GitClient.pullRequestRefPrefix(remote: "origin", number: 7) }

        func push(_ sha: String, to ref: String) async throws {
            try await publisher.git(["push", "--force", "origin", "\(sha):\(ref)"])
        }

        /// A commit of `file` on `branch`, which the publisher creates or continues.
        @discardableResult
        func commit(_ file: String, on branch: String, from start: String? = nil) async throws -> String {
            if let start {
                try await publisher.git(["switch", "-C", branch, start])
            } else {
                try await publisher.git(["switch", branch])
            }
            try publisher.write(file, "\(file)\n")
            return try await publisher.commit("Add \(file)")
        }

        /// Replaces what `ref` points to on the remote with a sibling commit of `start`.
        @discardableResult
        func rewrite(_ ref: String, from start: String) async throws -> String {
            let sha = try await commit("rewritten-\(UUID().uuidString)", on: "scratch", from: start)
            try await push(sha, to: ref)
            return sha
        }

        /// A pull request branch of one commit and a `main` that has moved one commit past
        /// their fork point, the root.
        func openPullRequest() async throws -> (head: String, baseTip: String) {
            let head = try await commit("feature.txt", on: "pr", from: root)
            let baseTip = try await commit("main.txt", on: "main")
            try await push(baseTip, to: "refs/heads/main")
            try await push(head, to: "refs/pull/7/head")
            return (head, baseTip)
        }

        /// A one-commit pull request head forked from the root, published as pull request 7.
        func publishHead() async throws -> String {
            let head = try await commit("feature.txt", on: "pr", from: root)
            try await push(head, to: "refs/pull/7/head")
            return head
        }

        func advertise() async throws -> AdvertisedPullRequest {
            try await client.advertisedPullRequest(number: 7, remote: "origin")
        }

        /// Advertises, fetches and returns the advertisement.
        func fetch() async throws -> AdvertisedPullRequest {
            let advertised = try await advertise()
            try await client.fetchPullRequest(advertised)
            return advertised
        }

        func base(of advertised: AdvertisedPullRequest) async throws -> PullRequestComparisonBase {
            try await client.pullRequestBase(headSHA: advertised.headSHA, baseTipSHA: advertised.baseTipSHA)
        }

        /// Makes `tip` the remote's `main` and expects the base to be the head's own history.
        func expectAlreadyInBase(tip: String) async throws {
            try await push(tip, to: "refs/heads/main")
            let advertised = try await fetch()
            await #expect(throws: PullRequestError.alreadyInBase) { try await base(of: advertised) }
        }

        func expectBase(of advertised: AdvertisedPullRequest, is commit: String, recovered: Bool = false) async throws {
            let base = try await base(of: advertised)
            #expect(base == PullRequestComparisonBase(commitSHA: commit, isRecovered: recovered))
        }
    }

    /// Drops every ref except the pins and prunes what is left unreachable, so only a pin
    /// can keep a commit alive.
    private func collectGarbage(in repo: Repo) async throws {
        let refs = try await repo.git(["for-each-ref", "--format=%(refname)"]).split(separator: "\n")
        for ref in refs where !ref.contains("/snapshots/") && !ref.contains("/base-tips/") {
            try await repo.git(["update-ref", "-d", String(ref)])
        }
        try await repo.git(["reflog", "expire", "--expire=now", "--all"])
        try await repo.git(["gc", "--prune=now", "--quiet"])
    }

    private func expectRetained(_ sha: String, pinnedAt ref: String, in repo: Repo) async throws {
        #expect(try await repo.git(["rev-parse", ref]) == sha)
        #expect(try await repo.git(["cat-file", "-t", sha]) == "commit")
    }

    // MARK: remotes

    @Test func remotesListsEachRemoteWithItsFirstRewrittenURL() async throws {
        let repo = try await committedRepo()
        try await repo.git(["config", "url.https://github.com/.insteadOf", "gh:"])
        try await repo.git(["remote", "add", "a", "https://example.com/a.git"])
        try await repo.git(["remote", "set-url", "--add", "a", "https://example.com/a-second.git"])
        try await repo.git(["remote", "add", "b", "gh:acme/widgets"])

        #expect(
            try await repo.client.remotes() == [
                GitRemote(name: "a", fetchURL: "https://example.com/a.git"),
                GitRemote(name: "b", fetchURL: "https://github.com/acme/widgets"),
            ])
    }

    // MARK: advertisement

    @Test func advertisementReportsTheRemoteNotTheStaleTrackingHead() async throws {
        let fixture = try await Fixture()
        let (head, _) = try await fixture.openPullRequest()
        let trunk = try await fixture.commit("trunk.txt", on: "trunk", from: fixture.root)
        try await fixture.push(trunk, to: "refs/heads/trunk")
        try await fixture.bare.git(["symbolic-ref", "HEAD", "refs/heads/trunk"])

        let advertised = try await fixture.advertise()

        #expect(
            advertised
                == AdvertisedPullRequest(
                    remote: "origin", number: 7, defaultBranch: "trunk", baseTipSHA: trunk, headSHA: head))
        #expect(
            try await fixture.clone.git(["symbolic-ref", "refs/remotes/origin/HEAD"]) == "refs/remotes/origin/main")
    }

    @Test func advertisementFailsWithoutAPullRef() async throws {
        let fixture = try await Fixture()
        _ = try await fixture.openPullRequest()

        await #expect(throws: PullRequestError.notFound) {
            try await fixture.client.advertisedPullRequest(number: 8, remote: "origin")
        }
    }

    @Test func advertisementFailsWithoutADefaultBranch() async throws {
        let fixture = try await Fixture()
        let (_, baseTip) = try await fixture.openPullRequest()

        // A detached HEAD advertises a commit but no symref.
        try await fixture.bare.git(["update-ref", "--no-deref", "HEAD", baseTip])
        await #expect(throws: PullRequestError.noDefaultBranch) { try await fixture.advertise() }
    }

    // MARK: fetch

    @Test func fetchWritesOnlyItsOwnRefsWhateverTheConfigSays() async throws {
        let fixture = try await Fixture()
        let (head, baseTip) = try await fixture.openPullRequest()
        let clone = fixture.clone
        try await clone.git(["config", "fetch.prune", "true"])
        try await clone.git(["config", "fetch.pruneTags", "true"])
        try await clone.git(["update-ref", "refs/remotes/origin/gone", fixture.root])
        try await clone.git(["tag", "local-only"])

        _ = try await fixture.fetch()

        #expect(try await clone.git(["rev-parse", "\(fixture.prefix)/head"]) == head)
        #expect(try await clone.git(["rev-parse", "\(fixture.prefix)/base"]) == baseTip)
        // Kept by the no-prune flags, and `origin/main` stays put because no mapping applies.
        #expect(try await clone.git(["rev-parse", "refs/remotes/origin/gone"]) == fixture.root)
        #expect(try await clone.git(["rev-parse", "refs/tags/local-only"]) == fixture.root)
        #expect(try await clone.git(["rev-parse", "refs/remotes/origin/main"]) == fixture.root)
        #expect(!FileManager.default.fileExists(atPath: clone.url.appendingPathComponent(".git/FETCH_HEAD").path))
    }

    // MARK: pinning

    @Test func aForcePushAfterTheFetchStillPinsTheAdvertisedCommit() async throws {
        let fixture = try await Fixture()
        let (head, baseTip) = try await fixture.openPullRequest()
        let advertised = try await fixture.fetch()

        try await fixture.rewrite("refs/pull/7/head", from: fixture.root)
        try await fixture.client.fetchPullRequest(advertised)
        #expect(try await fixture.clone.git(["rev-parse", "\(fixture.prefix)/head"]) != head)
        try await fixture.client.pinAdvertisedCommits(advertised)

        try await expectRetained(head, pinnedAt: "\(fixture.prefix)/snapshots/\(head)", in: fixture.clone)
        try await expectRetained(baseTip, pinnedAt: "\(fixture.prefix)/base-tips/\(baseTip)", in: fixture.clone)
    }

    @Test func aForcePushBeforeTheFetchLeavesTheAdvertisedCommitUnavailable() async throws {
        let fixture = try await Fixture()
        _ = try await fixture.openPullRequest()
        let advertised = try await fixture.advertise()

        try await fixture.rewrite("refs/pull/7/head", from: fixture.root)
        try await fixture.client.fetchPullRequest(advertised)

        await #expect(throws: PullRequestError.commitsUnavailable) {
            try await fixture.client.pinAdvertisedCommits(advertised)
        }
        #expect(try await fixture.clone.git(["for-each-ref", "\(fixture.prefix)/snapshots"]).isEmpty)
    }

    @Test func aPinnedHeadAndItsBaseSurviveALaterForcePushAndGc() async throws {
        let fixture = try await Fixture()
        let (head, _) = try await fixture.openPullRequest()
        let advertised = try await fixture.fetch()
        try await fixture.client.pinAdvertisedCommits(advertised)

        try await fixture.rewrite("refs/pull/7/head", from: fixture.root)
        _ = try await fixture.fetch()
        try await collectGarbage(in: fixture.clone)

        try await expectRetained(head, pinnedAt: "\(fixture.prefix)/snapshots/\(head)", in: fixture.clone)
        try await fixture.expectBase(of: advertised, is: fixture.root)
    }

    @Test func aPinnedBaseTipSurvivesTheRemoteRewritingTheBaseBranch() async throws {
        let fixture = try await Fixture()
        let (_, baseTip) = try await fixture.openPullRequest()
        let advertised = try await fixture.fetch()

        try await fixture.rewrite("refs/heads/main", from: fixture.root)
        try await fixture.client.fetchPullRequest(advertised)
        #expect(try await fixture.clone.git(["rev-parse", "\(fixture.prefix)/base"]) != baseTip)
        try await fixture.client.pinAdvertisedCommits(advertised)
        try await collectGarbage(in: fixture.clone)

        try await expectRetained(baseTip, pinnedAt: "\(fixture.prefix)/base-tips/\(baseTip)", in: fixture.clone)
        try await fixture.expectBase(of: advertised, is: fixture.root)
    }

    // MARK: comparison base

    @Test func aMergeCommitPullRequestRecoversItsForkPoint() async throws {
        let fixture = try await Fixture()
        let head = try await fixture.commit("feature.txt", on: "pr", from: fixture.root)
        try await fixture.commit("early.txt", on: "main")
        try await fixture.publisher.git(["merge", "--no-ff", "pr", "-m", "Merge pr"])
        let tip = try await fixture.commit("later.txt", on: "main")
        try await fixture.push(tip, to: "refs/heads/main")
        try await fixture.push(head, to: "refs/pull/7/head")

        let advertised = try await fixture.fetch()

        try await fixture.expectBase(of: advertised, is: fixture.root, recovered: true)
    }

    @Test func aHeadThatIsTheBaseTipHasNoEarlierBase() async throws {
        let fixture = try await Fixture()
        let head = try await fixture.publishHead()

        try await fixture.expectAlreadyInBase(tip: head)
    }

    @Test func aFastForwardedHeadHasNoEarlierBase() async throws {
        let fixture = try await Fixture()
        let head = try await fixture.publishHead()
        try await fixture.publisher.git(["switch", "-C", "main", head])

        try await fixture.expectAlreadyInBase(tip: try await fixture.commit("after.txt", on: "main"))
    }

    @Test func aHeadFollowedByAnUnrelatedMergeHasNoEarlierBase() async throws {
        let fixture = try await Fixture()
        let head = try await fixture.publishHead()
        let other = try await fixture.commit("other.txt", on: "other", from: fixture.root)
        // The first commit past the head merges something else in, with the head as first parent.
        try await fixture.publisher.git(["switch", "-C", "main", head])
        try await fixture.publisher.git(["merge", "--no-ff", other, "-m", "Merge other"])

        try await fixture.expectAlreadyInBase(tip: try await fixture.publisher.git(["rev-parse", "HEAD"]))
    }

    @Test func aSquashMergedPullRequestKeepsItsMergeBase() async throws {
        let fixture = try await Fixture()
        let head = try await fixture.commit("feature.txt", on: "pr", from: fixture.root)
        let squash = try await fixture.commit("feature-squashed.txt", on: "main")
        try await fixture.push(squash, to: "refs/heads/main")
        try await fixture.push(head, to: "refs/pull/7/head")

        let advertised = try await fixture.fetch()

        try await fixture.expectBase(of: advertised, is: fixture.root)
    }

    @Test func unrelatedHistoriesShareNothing() async throws {
        let fixture = try await Fixture()
        try await fixture.publisher.git(["checkout", "--orphan", "unrelated"])
        let head = try await fixture.publisher.commit("Unrelated root")
        try await fixture.push(head, to: "refs/pull/7/head")

        let advertised = try await fixture.fetch()

        await #expect(throws: PullRequestError.noCommonHistory(isShallow: false)) {
            try await fixture.base(of: advertised)
        }
    }

    /// A pull request forked three commits behind the tip of `main`.
    private func shallowFixture() async throws -> (fixture: Fixture, fork: String, head: String, tip: String) {
        let fixture = try await Fixture()
        let fork = try await fixture.commit("fork.txt", on: "main")
        let head = try await fixture.commit("feature.txt", on: "pr", from: fork)
        try await fixture.commit("one.txt", on: "main")
        try await fixture.commit("two.txt", on: "main")
        let tip = try await fixture.commit("three.txt", on: "main")
        try await fixture.push(tip, to: "refs/heads/main")
        try await fixture.push(head, to: "refs/pull/7/head")
        return (fixture, fork, head, tip)
    }

    private func shallowClone(of fixture: Fixture, depth: Int) async throws -> Repo {
        let clone = try Repo()
        try await clone.git(["clone", "--depth", "1", "file://\(fixture.bare.url.path)", "."])
        try await clone.git(
            [
                "fetch", "--depth", "\(depth)", "origin", "refs/pull/7/head:refs/scratch/head",
                "refs/heads/main:refs/scratch/base",
            ])
        return clone
    }

    @Test func aShallowCloneWithEnoughHistoryMeetsTheBase() async throws {
        let (fixture, fork, _, _) = try await shallowFixture()

        // Three commits past the fork on one side and one on the other.
        let clone = try await shallowClone(of: fixture, depth: 4)
        let advertised = try await clone.client.advertisedPullRequest(number: 7, remote: "origin")
        let resolved = try await clone.client.pullRequestBase(
            headSHA: advertised.headSHA, baseTipSHA: advertised.baseTipSHA)

        #expect(resolved == PullRequestComparisonBase(commitSHA: fork, isRecovered: false))
    }

    @Test func aShallowCloneWithoutEnoughHistoryReportsIt() async throws {
        let (fixture, _, head, tip) = try await shallowFixture()

        let clone = try await shallowClone(of: fixture, depth: 1)

        await #expect(throws: PullRequestError.noCommonHistory(isShallow: true)) {
            try await clone.client.pullRequestBase(headSHA: head, baseTipSHA: tip)
        }
    }
}
