import Foundation
import Testing

@testable import DiffViewer

/// A window's connection model: which results publish, when progress shows, and how rechecks
/// coalesce. Checks and the progress delay are controlled calls; nothing waits on a clock.
@MainActor
struct GitHubConnectionModelTests {
    private static let widgets = GitHubRepository(owner: "acme", name: "widgets")
    private static let gadgets = GitHubRepository(owner: "acme", name: "gadgets")
    private static let url = URL(string: "https://github.com/acme/widgets")!
    private static let found = GitHubRepositoryCheck.token(
        source: .gitHubCLI, login: "me", access: .found(isPrivate: false, url: url))
    private static let signedIn = GitHubAuthenticationStatus.token(source: .gitHubCLI, login: "me")

    /// A model on controlled calls, recording what it publishes.
    @MainActor
    private final class Fixture {
        let repositoryChecks = ControlledCalls<GitHubRepository, GitHubRepositoryCheck>()
        let statusChecks = ControlledCalls<Void, GitHubAuthenticationStatus>()
        let sleeps = ControlledCalls<Duration, Void>()
        let environmentRefreshes = ControlledCalls<Void, Void>()
        private(set) var published: [(revision: Int, result: GitHubCheckResult)] = []
        private var revision = 0
        private(set) var model: GitHubConnectionModel!

        init() {
            let (repositoryChecks, statusChecks, sleeps, environmentRefreshes) =
                (repositoryChecks, statusChecks, sleeps, environmentRefreshes)
            model = GitHubConnectionModel(
                checkRepository: { try await repositoryChecks.call($0) },
                checkStatus: { try await statusChecks.call() },
                beginEnvironmentRefresh: { try? await environmentRefreshes.call() },
                issueRevision: { [weak self] in
                    guard let self else { return 0 }
                    revision += 1
                    return revision
                },
                onPublish: { [weak self] in self?.published.append(($0, $1)) },
                sleep: { try await sleeps.call($0) })
        }

        deinit {
            repositoryChecks.cancelAll()
            statusChecks.cancelAll()
            sleeps.cancelAll()
            environmentRefreshes.cancelAll()
        }

        var results: [GitHubCheckResult] { published.map(\.result) }
    }

    /// Starts a check of `widgets` and waits until it is with the client.
    private func startChecking(_ f: Fixture) async throws {
        f.model.observeOrigin(.repository(Self.widgets), wantsStatus: true)
        try #require(await eventually { @MainActor in f.repositoryChecks.count == 1 })
    }

    /// Starts a check of `widgets` and lets its progress delay run out.
    private func startShowingProgress(_ f: Fixture) async throws {
        try await startChecking(f)
        try #require(await eventually { @MainActor in f.sleeps.count == 1 })
        f.sleeps.succeed(0, with: ())
        try #require(await eventually { @MainActor in f.model.showsProgress })
    }

    // MARK: Freshness

    @Test func aCheckForAReplacedOriginNeverPublishesNorTouchesItsReplacement() async throws {
        let f = Fixture()
        try await startChecking(f)
        f.model.observeOrigin(.repository(Self.gadgets), wantsStatus: true)
        try #require(await eventually { @MainActor in f.repositoryChecks.count == 2 && f.sleeps.count == 2 })
        f.sleeps.succeedAll(with: ())
        try #require(await eventually { @MainActor in f.model.showsProgress })

        f.repositoryChecks.succeed(0, with: Self.found)
        try #require(await eventually { @MainActor in f.model.checksFinished == 1 })
        #expect(f.published.isEmpty)
        #expect(f.model.connection == nil)
        #expect(f.model.isChecking)
        #expect(f.model.showsProgress)
    }

    @Test func movingOffGitHubPublishesOnceAndALateCheckAddsNothing() async throws {
        let f = Fixture()
        f.model.observeOrigin(.repository(Self.widgets), wantsStatus: false)
        try #require(await eventually { @MainActor in f.repositoryChecks.count == 1 })
        f.model.observeOrigin(.none, wantsStatus: false)

        f.repositoryChecks.succeed(0, with: Self.found)
        try #require(await eventually { @MainActor in f.model.checksFinished == 1 })
        #expect(f.results == [.notOnGitHub])
        #expect(f.model.connection == .notOnGitHub)
    }

    @Test func anUpstreamOnlyRepositoryPublishesTheStatus() async throws {
        let f = Fixture()
        f.model.observeOrigin(.none, wantsStatus: true)
        try #require(await eventually { @MainActor in f.statusChecks.count == 1 })

        f.statusChecks.succeed(0, with: Self.signedIn)
        try #require(await eventually { @MainActor in f.model.checksFinished == 1 })
        #expect(f.results.last == .statusOnly(Self.signedIn))
    }

    @Test func theFirstGitHubUpstreamStartsAStatusCheck() async throws {
        let f = Fixture()
        f.model.observeOrigin(.none, wantsStatus: false)
        #expect(f.model.observeOrigin(.none, wantsStatus: true))
        #expect(await eventually { @MainActor in f.statusChecks.count == 1 })
    }

    @Test func losingTheLastGitHubUpstreamDropsTheRunningStatusCheck() async throws {
        let f = Fixture()
        f.model.observeOrigin(.none, wantsStatus: true)
        try #require(await eventually { @MainActor in f.statusChecks.count == 1 })
        f.model.observeOrigin(.none, wantsStatus: false)

        f.statusChecks.succeed(0, with: Self.signedIn)
        try #require(await eventually { @MainActor in f.model.checksFinished == 1 })
        #expect(f.results == [.notOnGitHub])
    }

    @Test func aTransientFailureAfterAnOriginChangeIsUnreachable() async throws {
        let f = Fixture()
        try await startChecking(f)
        f.repositoryChecks.succeed(0, with: Self.found)
        try #require(await eventually { @MainActor in f.model.checksFinished == 1 })
        f.model.observeOrigin(.repository(Self.gadgets), wantsStatus: true)
        try #require(await eventually { @MainActor in f.repositoryChecks.count == 2 })

        f.repositoryChecks.succeed(1, with: .token(source: .gitHubCLI, login: "me", access: .transient))
        try #require(await eventually { @MainActor in f.model.checksFinished == 2 })
        #expect(f.model.connection == .unreachable(Self.gadgets))
    }

    @Test func movingOffGitHubPublishesUnderANewRevision() async throws {
        let f = Fixture()
        try await startChecking(f)
        f.repositoryChecks.succeed(0, with: Self.found)
        try #require(await eventually { @MainActor in f.model.checksFinished == 1 })
        let connectedRevision = try #require(f.published.last?.revision)

        f.model.observeOrigin(.none, wantsStatus: false)
        #expect(f.published.last?.result == .notOnGitHub)
        #expect((f.published.last?.revision ?? 0) > connectedRevision)
    }

    @Test func afterStopALateCheckPublishesNothing() async throws {
        let f = Fixture()
        try await startChecking(f)
        f.model.stop()

        f.repositoryChecks.succeed(0, with: Self.found)
        try #require(await eventually { @MainActor in f.model.checksFinished == 1 })
        #expect(f.published.isEmpty)
        #expect(f.model.connection == nil)
    }

    // MARK: Progress

    @Test func progressShowsOnceTheDelayEndsWithTheCheckRunning() async throws {
        let f = Fixture()
        try await startChecking(f)
        try #require(await eventually { @MainActor in f.sleeps.count == 1 })
        #expect(!f.model.showsProgress)

        f.sleeps.succeed(0, with: ())
        #expect(await eventually { @MainActor in f.model.showsProgress })
    }

    @Test func completionHidesProgress() async throws {
        let f = Fixture()
        try await startShowingProgress(f)

        f.repositoryChecks.succeed(0, with: Self.found)
        try #require(await eventually { @MainActor in f.model.checksFinished == 1 })
        #expect(!f.model.showsProgress)
    }

    @Test func cancellationHidesProgress() async throws {
        let f = Fixture()
        try await startShowingProgress(f)

        f.model.observeOrigin(.none, wantsStatus: false)
        #expect(!f.model.showsProgress)
    }

    // MARK: Rechecks

    @Test func rechecksDuringACheckRunExactlyOneFollowUp() async throws {
        let f = Fixture()
        try await startChecking(f)
        f.model.recheck()
        f.model.recheck()
        f.model.recheck()

        f.repositoryChecks.succeed(0, with: Self.found)
        try #require(await eventually { @MainActor in f.repositoryChecks.count == 2 })
        f.repositoryChecks.succeed(1, with: Self.found)
        try #require(await eventually { @MainActor in f.model.checksFinished == 2 })
        #expect(f.repositoryChecks.count == 2)
    }

    @Test func aMergedEnvironmentRefreshRunsBeforeTheFollowUp() async throws {
        let f = Fixture()
        try await startChecking(f)
        f.model.recheck(refreshingEnvironment: true)
        f.model.recheck()
        #expect(f.environmentRefreshes.arguments.isEmpty)

        f.repositoryChecks.succeed(0, with: Self.found)
        try #require(await eventually { @MainActor in f.environmentRefreshes.count == 1 })
        // Held until the refresh has started, so the follow-up's credentials can't be read first.
        #expect(f.repositoryChecks.count == 1)

        f.environmentRefreshes.succeed(0, with: ())
        try #require(await eventually { @MainActor in f.repositoryChecks.count == 2 })
    }
}
