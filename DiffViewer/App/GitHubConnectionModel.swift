import Foundation
import Observation

/// One window's GitHub connection: which origin it is about, the last result for that origin,
/// and the check that keeps it fresh. Results for an origin the window has moved away from never
/// publish, and connection checks never touch the pull request lookup.
@MainActor
@Observable
final class GitHubConnectionModel {
    /// The origin a result must be about.
    enum OriginIdentity: Equatable, Sendable {
        /// The remotes haven't been read yet.
        case unknown
        /// Origin is missing or not on GitHub.
        case none
        case repository(GitHubRepository)

        /// Repositories compare as GitHub does, ignoring case.
        static func == (lhs: OriginIdentity, rhs: OriginIdentity) -> Bool {
            switch (lhs, rhs) {
            case (.unknown, .unknown), (.none, .none): true
            case let (.repository(left), .repository(right)): left.matches(right)
            default: false
            }
        }
    }

    /// A recheck asked for while a check ran; the follow-up runs once it ends.
    private struct PendingRecheck {
        var refreshesEnvironment: Bool
    }

    /// What a check brought back, before it is derived against the current state.
    private enum Answer {
        case repository(GitHubRepositoryCheck)
        case status(GitHubAuthenticationStatus)
    }

    static let progressDelay: Duration = .milliseconds(300)

    private(set) var origin: OriginIdentity = .unknown
    /// Nil until a result for this origin arrives.
    private(set) var connection: GitHubConnection?
    /// A check has run long enough to show a spinner. Presentation only.
    private(set) var showsProgress = false

    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var delayTask: Task<Void, Never>?
    /// The revision the running check may publish under; nil when nothing may publish.
    @ObservationIgnored private var activeRevision: Int?
    @ObservationIgnored private var pending: PendingRecheck?
    /// Whether any remote is on GitHub, so an origin that isn't still wants the token's status.
    @ObservationIgnored private var wantsStatus = false
    @ObservationIgnored private var isStopped = false
    /// Incremented when a check's task ends, whether it published or not. Lets tests wait for
    /// the handling rather than for the client's answer.
    @ObservationIgnored private(set) var checksFinished = 0

    /// Both checks throw only `CancellationError`, as the `RepoClient` calls behind them do.
    @ObservationIgnored private let checkRepository: @Sendable (GitHubRepository) async throws -> GitHubRepositoryCheck
    @ObservationIgnored private let checkStatus: @Sendable () async throws -> GitHubAuthenticationStatus
    @ObservationIgnored private let beginEnvironmentRefresh: @MainActor () async -> Void
    @ObservationIgnored private let issueRevision: @MainActor () -> Int
    @ObservationIgnored private let onPublish: @MainActor (_ revision: Int, GitHubCheckResult) -> Void
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(
        checkRepository: @escaping @Sendable (GitHubRepository) async throws -> GitHubRepositoryCheck,
        checkStatus: @escaping @Sendable () async throws -> GitHubAuthenticationStatus,
        beginEnvironmentRefresh: @escaping @MainActor () async -> Void,
        issueRevision: @escaping @MainActor () -> Int,
        onPublish: @escaping @MainActor (_ revision: Int, GitHubCheckResult) -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.checkRepository = checkRepository
        self.checkStatus = checkStatus
        self.beginEnvironmentRefresh = beginEnvironmentRefresh
        self.issueRevision = issueRevision
        self.onPublish = onPublish
        self.sleep = sleep
    }

    /// A check is running.
    var isChecking: Bool { requestTask != nil }

    /// Takes in the origin from a remote read, and whether any remote is on GitHub. Returns
    /// whether a check started. Repeated reads of the same origin change nothing, so they never
    /// invalidate a running check.
    @discardableResult
    func observeOrigin(_ new: OriginIdentity, wantsStatus newWantsStatus: Bool) -> Bool {
        guard !isStopped else { return false }
        let oldWantsStatus = wantsStatus
        wantsStatus = newWantsStatus
        if new != origin {
            invalidate()
            origin = new
            if new == .none {
                connection = .notOnGitHub
                // The directory follows even though no check runs.
                onPublish(issueRevision(), .notOnGitHub)
            } else {
                connection = nil
            }
            return startCheckIfNeeded(refreshingEnvironment: false)
        }
        // Without a GitHub origin, only the status check depends on the other remotes.
        guard origin == .none, oldWantsStatus != newWantsStatus else { return false }
        if newWantsStatus { return startCheckIfNeeded(refreshingEnvironment: false) }
        invalidate()
        return false
    }

    /// Checks the current origin again. During a check, requests merge into one follow-up,
    /// which refreshes the environment first if any of them asked to.
    func recheck(refreshingEnvironment: Bool = false) {
        guard !isStopped else { return }
        if isChecking {
            let refreshes = (pending?.refreshesEnvironment ?? false) || refreshingEnvironment
            pending = PendingRecheck(refreshesEnvironment: refreshes)
            return
        }
        startCheckIfNeeded(refreshingEnvironment: refreshingEnvironment)
    }

    /// Ends this model's work for good: nothing running publishes, and nothing new starts.
    func stop() {
        invalidate()
        isStopped = true
    }

    // MARK: Checking

    /// Revokes the running check's right to publish before cancelling it, so a task that
    /// finishes anyway finds itself replaced.
    private func invalidate() {
        activeRevision = nil
        requestTask?.cancel()
        requestTask = nil
        delayTask?.cancel()
        delayTask = nil
        pending = nil
        showsProgress = false
    }

    @discardableResult
    private func startCheckIfNeeded(refreshingEnvironment: Bool) -> Bool {
        switch origin {
        case .repository: break
        case .none where wantsStatus: break
        default: return false
        }
        let revision = issueRevision()
        activeRevision = revision
        let origin = origin
        requestTask = Task { [weak self, checkRepository, checkStatus, beginEnvironmentRefresh] in
            if refreshingEnvironment { await beginEnvironmentRefresh() }
            let answer: Answer?
            switch origin {
            case let .repository(repository):
                answer = (try? await checkRepository(repository)).map(Answer.repository)
            default:
                answer = (try? await checkStatus()).map(Answer.status)
            }
            self?.finish(revision: revision, origin: origin, answer: answer)
        }
        delayTask = Task { [weak self, sleep] in
            do { try await sleep(Self.progressDelay) } catch { return }
            guard let self, !Task.isCancelled, activeRevision == revision, isChecking else { return }
            showsProgress = true
        }
        return true
    }

    /// A replaced check leaves its replacement's state alone. A nil answer is a cancelled check,
    /// the only way the checks throw, and publishes nothing.
    private func finish(revision: Int, origin: OriginIdentity, answer: Answer?) {
        defer { checksFinished += 1 }
        guard revision == activeRevision else { return }
        activeRevision = nil
        requestTask = nil
        delayTask?.cancel()
        delayTask = nil
        showsProgress = false
        if let answer, !Task.isCancelled, origin == self.origin {
            publish(answer, revision: revision)
        }
        guard let pending else { return }
        self.pending = nil
        startCheckIfNeeded(refreshingEnvironment: pending.refreshesEnvironment)
    }

    private func publish(_ answer: Answer, revision: Int) {
        switch (answer, origin) {
        case let (.repository(check), .repository(repository)):
            let outcome = GitHubCheckOutcome.make(origin: repository, check: check, previous: connection)
            connection = outcome.connection
            onPublish(revision, .repository(outcome))
        case let (.status(status), _):
            onPublish(revision, .statusOnly(status))
        default:
            break
        }
    }
}
