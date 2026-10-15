import Foundation
import Observation

/// How much the current request changes.
enum ComparisonChurn: Equatable {
    /// There is no comparison request.
    case hidden
    /// Waiting for the debounce or a read; the view draws nothing yet.
    case pending
    /// The read is taking long enough to show a spinner.
    case comparing
    case noDifferences
    case ready(IncomingChangeSummary)
    /// Opening may still work: only the commit range must resolve.
    case failed(String)
}

/// The current request's resolution state.
enum ComparisonResolutionState: Equatable {
    case idle
    case resolving
    case resolved(CommitRange)
    case failed(String)
}

/// Thrown by a resolver to show its own wording.
struct ComparisonFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// Resolves the latest request to a commit range after a debounce, then reads its churn.
/// Reads run one at a time, and only the latest request may publish.
@MainActor
@Observable
final class ComparisonPreview<Request: Sendable & Equatable> {
    /// `isCurrent` turns false once the request is superseded or the preview closes, so a
    /// resolver can skip its remaining steps.
    typealias Resolve = @MainActor (Request, _ isCurrent: @MainActor () -> Bool) async throws -> CommitRange

    enum Outcome: Sendable, Equatable {
        case range(CommitRange)
        case failed(String)
    }

    private(set) var churn: ComparisonChurn = .hidden
    private(set) var resolution: ComparisonResolutionState = .idle

    @ObservationIgnored private let client: any RepoClient
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let spinnerDelay: Duration
    @ObservationIgnored private let resolve: Resolve

    /// Nil when there is nothing to compare.
    @ObservationIgnored private(set) var request: Request?
    /// Bumped by every request change and by `close()`; a read whose generation is stale
    /// publishes nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isClosed = false
    /// Exposed so tests can await it.
    @ObservationIgnored private(set) var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?
    /// The next read; a newer request replaces it rather than queueing behind it.
    @ObservationIgnored private var queued: Pending?
    @ObservationIgnored private var running: Pending?
    /// Runs queued reads one at a time. Exposed so tests can await it.
    @ObservationIgnored private(set) var readTask: Task<Void, Never>?
    @ObservationIgnored private var waiters: [Waiter] = []

    private struct Pending {
        let generation: Int
        let request: Request
    }

    /// A caller waiting for the range; nil means the preview closed or the request changed.
    private struct Waiter {
        let generation: Int
        let continuation: CheckedContinuation<Outcome?, Never>
    }

    /// `resolve` is stored, so it must not capture the preview's owner.
    init(
        client: any RepoClient, clock: any Clock<Duration>, debounce: Duration, spinnerDelay: Duration,
        resolve: @escaping Resolve
    ) {
        self.client = client
        self.clock = clock
        self.debounce = debounce
        self.spinnerDelay = spinnerDelay
        self.resolve = resolve
    }

    // MARK: Requests

    /// An equal request changes nothing, so edits that don't change it start no read.
    func setRequest(_ request: Request?) {
        guard !isClosed, request != self.request else { return }
        self.request = request
        generation += 1
        debounceTask?.cancel()
        spinnerTask?.cancel()
        resolution = .idle
        resumeAllWaiters()
        guard let request else {
            churn = .hidden
            queued = nil
            return
        }
        churn = .pending
        let pending = Pending(generation: generation, request: request)
        debounceTask = Task { [weak self, clock, debounce] in
            do { try await Task.sleep(for: debounce, clock: clock) } catch { return }
            guard let self, generation == pending.generation else { return }
            enqueue(pending)
        }
        spinnerTask = Task { [weak self, clock, spinnerDelay] in
            do { try await Task.sleep(for: spinnerDelay, clock: clock) } catch { return }
            guard let self, generation == pending.generation, churn == .pending else { return }
            churn = .comparing
        }
    }

    /// Skips the debounce. A running, queued or successful read is reused; a failed one
    /// reads again.
    func resolveNow() {
        guard !isClosed, let request else { return }
        debounceTask?.cancel()
        if case .resolved = resolution { return }
        guard running?.generation != generation, queued?.generation != generation else { return }
        enqueue(Pending(generation: generation, request: request))
    }

    /// The current request's range once it resolves; the churn is not awaited. Nil means
    /// the preview closed or the request changed.
    func resolvedRange() async -> Outcome? {
        guard !isClosed, request != nil else { return nil }
        if case let .resolved(range) = resolution { return .range(range) }
        resolveNow()
        let generation = generation
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(generation: generation, continuation: continuation))
        }
    }

    // MARK: Reads

    private func enqueue(_ pending: Pending) {
        queued = pending
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            await self?.drain()
            self?.readTask = nil
        }
    }

    private func drain() async {
        while let pending = queued, !isClosed {
            queued = nil
            guard pending.generation == generation else { continue }
            await run(pending)
        }
    }

    private func isCurrent(_ pending: Pending) -> Bool {
        !isClosed && generation == pending.generation
    }

    private func run(_ pending: Pending) async {
        running = pending
        defer { running = nil }
        resolution = .resolving
        let range: CommitRange
        do {
            range = try await resolve(pending.request) { [weak self] in self?.isCurrent(pending) ?? false }
            guard isCurrent(pending) else { return }
        } catch {
            guard isCurrent(pending) else { return }
            fail(pending, error.localizedDescription)
            return
        }
        resolution = .resolved(range)
        // A waiting caller needs only the range, not the counts.
        resumeWaiters(for: pending.generation, with: .range(range))
        do {
            let summary = try await client.churn(base: range.mergeBaseSHA, target: range.targetSHA)
            guard isCurrent(pending) else { return }
            publish(summary.fileCount == 0 ? .noDifferences : .ready(summary))
        } catch {
            guard isCurrent(pending) else { return }
            publish(.failed(error.localizedDescription))
        }
    }

    /// A failure is not kept as a result: `resolveNow()` resolves again.
    private func fail(_ pending: Pending, _ message: String) {
        resolution = .failed(message)
        resumeWaiters(for: pending.generation, with: .failed(message))
        publish(.failed(message))
    }

    private func publish(_ result: ComparisonChurn) {
        spinnerTask?.cancel()
        churn = result
    }

    private func resumeWaiters(for generation: Int, with outcome: Outcome) {
        let ready = waiters.filter { $0.generation == generation }
        waiters.removeAll { $0.generation == generation }
        for waiter in ready { waiter.continuation.resume(returning: outcome) }
    }

    private func resumeAllWaiters() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.continuation.resume(returning: nil) }
    }

    /// Called when the owner goes away: queued work is dropped and the results of reads
    /// already running are ignored (running git reads are not killed).
    func close() {
        isClosed = true
        generation += 1
        queued = nil
        debounceTask?.cancel()
        spinnerTask?.cancel()
        resumeAllWaiters()
    }
}
