import Foundation
import Testing

@testable import DiffViewer

/// The repository picker's connections: which result is kept, how background checks are
/// bounded, and when their environments are dropped.
@MainActor
struct GitHubConnectionDirectoryTests {
    private static let a = RepositoryRoot(path: "/DirectoryA")
    private static let b = RepositoryRoot(path: "/DirectoryB")
    private static let c = RepositoryRoot(path: "/DirectoryC")
    private static let d = RepositoryRoot(path: "/DirectoryD")
    private static let widgets = GitHubRepository(owner: "acme", name: "widgets")
    private static let url = URL(string: "https://github.com/acme/widgets")!
    private static let connected = GitHubConnection.connected(
        widgets, login: "me", source: .gitHubCLI, isPrivate: false, url: url)
    private static let unreachable = GitHubConnection.unreachable(widgets)

    /// Which repositories have a window, and how many background loads run at once.
    @MainActor
    private final class Windows {
        var models: [RepositoryRoot: GitHubConnectionModel] = [:]
        private(set) var runningLoads = 0
        private(set) var mostRunningLoads = 0

        func loadStarted() {
            runningLoads += 1
            mostRunningLoads = max(mostRunningLoads, runningLoads)
        }

        func loadEnded() { runningLoads -= 1 }
    }

    private let loads = ControlledCalls<RepositoryRoot, GitHubConnection>()
    private let windows = Windows()
    private let environment = EnvironmentRecorder()
    private let directory: GitHubConnectionDirectory

    init() {
        let (loads, windows) = (loads, windows)
        directory = GitHubConnectionDirectory(lifecycle: environment.lifecycle) { root, _ in
            windows.loadStarted()
            defer { windows.loadEnded() }
            return try await loads.call(root)
        }
        directory.openModel = { windows.models[$0] }
    }

    /// A window's model whose checks end as cancelled, so it never publishes.
    private func silentModel() -> GitHubConnectionModel {
        GitHubConnectionModel(
            checkRepository: { _ in throw CancellationError() },
            checkStatus: { throw CancellationError() },
            beginEnvironmentRefresh: {}, issueRevision: { 0 }, onPublish: { _, _ in })
    }

    private func finished(_ count: Int) async -> Bool {
        await eventually { @MainActor in directory.checksFinished == count }
    }

    // MARK: Revisions

    @Test(arguments: [true, false])
    func theLaterIssuedRevisionWinsWhicheverFinishesFirst(windowFinishesFirst: Bool) async throws {
        defer { loads.cancelAll() }
        directory.revalidate([Self.a])
        try #require(await eventually { @MainActor in loads.count == 1 })
        let windowRevision = directory.issueRevision(for: Self.a)

        if windowFinishesFirst {
            directory.publish(root: Self.a, revision: windowRevision, connection: Self.connected)
            loads.succeed(0, with: Self.unreachable)
            try #require(await finished(1))
        } else {
            loads.succeed(0, with: Self.unreachable)
            try #require(await finished(1))
            directory.publish(root: Self.a, revision: windowRevision, connection: Self.connected)
        }
        #expect(directory.connection(for: Self.a) == Self.connected)
    }

    @Test func anOlderResultFinishingWhileANewerCheckRunsIsNotStored() async throws {
        defer { loads.cancelAll() }
        directory.revalidate([Self.a])
        try #require(await eventually { @MainActor in loads.count == 1 })
        _ = directory.issueRevision(for: Self.a)

        loads.succeed(0, with: Self.connected)
        try #require(await finished(1))
        #expect(directory.connection(for: Self.a) == nil)
    }

    @Test func aWindowMovingOffGitHubLeavesNotOnGitHubOnceItCloses() async throws {
        let checks = ControlledCalls<GitHubRepository, GitHubRepositoryCheck>()
        defer { checks.cancelAll() }
        let directory = directory
        let model = GitHubConnectionModel(
            checkRepository: { try await checks.call($0) },
            checkStatus: { .anonymous },
            beginEnvironmentRefresh: {},
            issueRevision: { directory.issueRevision(for: Self.a) },
            onPublish: { revision, result in
                switch result {
                case let .repository(outcome):
                    directory.publish(root: Self.a, revision: revision, connection: outcome.connection)
                case .notOnGitHub:
                    directory.publish(root: Self.a, revision: revision, connection: .notOnGitHub)
                case .statusOnly:
                    break
                }
            })
        windows.models[Self.a] = model
        model.observeOrigin(.repository(Self.widgets), wantsStatus: true)
        try #require(await eventually { @MainActor in checks.count == 1 })
        let found = GitHubRepositoryAccess.found(isPrivate: false, url: Self.url)
        checks.succeed(0, with: .token(source: .gitHubCLI, login: "me", access: found))
        try #require(await eventually { @MainActor in model.connection == Self.connected })

        model.observeOrigin(.none, wantsStatus: false)
        model.stop()
        windows.models[Self.a] = nil
        #expect(directory.connection(for: Self.a) == .notOnGitHub)
    }

    // MARK: Background checks

    @Test func repeatedRevalidationKeepsTwoChecksAtATimeAndAsksForEachRootOnce() async throws {
        defer { loads.cancelAll() }
        directory.revalidate([Self.a, Self.b, Self.c])
        try #require(await eventually { @MainActor in loads.count == 2 })
        directory.revalidate([Self.a, Self.b, Self.c, Self.d])

        for index in 0..<4 {
            try #require(await eventually { @MainActor in loads.count > index })
            loads.succeed(index, with: Self.connected)
        }
        try #require(await finished(4))
        // Concurrent loads reach the loader in either order; each root is asked for once.
        #expect(loads.count == 4)
        #expect(Set(loads.arguments) == [Self.a, Self.b, Self.c, Self.d])
        #expect(windows.mostRunningLoads == 2)
    }

    @Test func dismissingThePickerDropsChecksThatHaveNotStarted() async throws {
        defer { loads.cancelAll() }
        directory.revalidate([Self.a, Self.b, Self.c])
        try #require(await eventually { @MainActor in loads.count == 2 })

        directory.cancelQueuedRevalidation()
        loads.succeedAll(with: Self.connected)
        try #require(await finished(2))
        #expect(Set(loads.arguments) == [Self.a, Self.b])
    }

    @Test func aRootOpenedDuringItsCheckKeepsItsEnvironmentAndDropsTheResult() async throws {
        defer { loads.cancelAll() }
        directory.revalidate([Self.a])
        try #require(await eventually { @MainActor in loads.count == 1 })
        windows.models[Self.a] = silentModel()
        _ = directory.issueRevision(for: Self.a)

        loads.succeed(0, with: Self.connected)
        try #require(await finished(1))
        #expect(environment.count(.forget, Self.a) == 0)
        windows.models[Self.a] = nil
        #expect(directory.connection(for: Self.a) == nil)
    }

    @Test func aFailedLoadKeepsTheStoredResult() async throws {
        defer { loads.cancelAll() }
        directory.revalidate([Self.a])
        try #require(await eventually { @MainActor in loads.count == 1 })
        loads.succeed(0, with: Self.connected)
        try #require(await finished(1))

        directory.revalidate([Self.a])
        try #require(await eventually { @MainActor in loads.count == 2 })
        loads.fail(1, with: ProcessError.failed(command: "git remote", status: 128, stderr: "gone"))
        try #require(await finished(2))
        #expect(directory.connection(for: Self.a) == Self.connected)
    }

    // MARK: The real loader

    @Test(
        arguments: [
            (
                ["origin": "git@github.com:acme/widgets.git"],
                .connected(
                    GitHubRepository(owner: "acme", name: "widgets"), login: "me", source: .gitHubCLI,
                    isPrivate: false, url: URL(string: "https://github.com/acme/widgets")!)
            ),
            (
                ["origin": "git@gitlab.com:acme/widgets.git", "upstream": "git@github.com:acme/widgets.git"],
                .notOnGitHub
            ),
            (["upstream": "git@github.com:acme/widgets.git"], .notOnGitHub),
        ] as [([String: String], GitHubConnection)])
    func theClosedLoaderChecksOnlyAGitHubOrigin(fetchURLs: [String: String], expected: GitHubConnection) async throws {
        let client = StubRepoClient(files: [])
        await client.set(remoteURLs: fetchURLs.mapValues { RemoteURLs(fetchURL: $0, pushURLs: [$0]) })
        await client.set(gitHubAuthenticationStatus: .token(source: .gitHubCLI, login: "me"))
        let root = Self.a
        let load = GitHubConnectionDirectory.closedLoader(
            discover: { _ in (root: root, client: client as any RepoClient) }, lifecycle: environment.lifecycle)

        #expect(try await load(Self.a, nil) == expected)
    }

    @Test func theClosedLoaderThrowsWhenTheRemotesCannotBeRead() async throws {
        let client = StubRepoClient(files: [])
        await client.fail(remoteURLs: true)
        let root = Self.a
        let load = GitHubConnectionDirectory.closedLoader(
            discover: { _ in (root: root, client: client as any RepoClient) }, lifecycle: environment.lifecycle)

        await #expect(throws: ProcessError.self) { try await load(Self.a, Self.connected) }
    }

    @Test func theClosedLoaderThrowsWhenDiscoveryFindsAnotherRepository() async throws {
        let client = StubRepoClient(files: [])
        await client.set(remoteURLs: ["origin": RemoteURLs(fetchURL: "git@github.com:acme/widgets.git", pushURLs: [])])
        let parent = RepositoryRoot(path: "/tmp")
        let load = GitHubConnectionDirectory.closedLoader(
            discover: { _ in (root: parent, client: client as any RepoClient) }, lifecycle: environment.lifecycle)

        await #expect(throws: GitHubConnectionDirectory.MovedRepositoryError.self) {
            try await load(Self.a, Self.connected)
        }
    }
}
