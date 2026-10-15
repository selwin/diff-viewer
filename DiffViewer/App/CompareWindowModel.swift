import Foundation
import Observation

/// What the Compare window shows and does: two filtered ref lists, the chosen base and
/// target, a preview of how much the target changed since their merge base, and opening
/// that range as a comparison tab. Reads run one at a time, and only the latest
/// selection may publish.
@MainActor
@Observable
final class CompareWindowModel {
    enum Side {
        case base
        case target
    }

    enum RefList: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// The preview under the two wells.
    enum Churn: Equatable {
        /// A side is missing.
        case hidden
        /// Waiting for the debounce or a read; the view draws nothing yet.
        case pending
        /// The read is taking long enough to show a spinner.
        case comparing
        case noDifferences
        case ready(IncomingChangeSummary)
        /// Opening may still work: only the merge base must resolve.
        case failed(String)
    }

    var baseQuery = ""
    var targetQuery = ""
    private(set) var refList: RefList = .loading
    /// Sorted once, by `CompareRefOrdering`.
    private(set) var refs: [GitRef] = []
    private(set) var base: GitRef?
    private(set) var target: GitRef?
    private(set) var churn: Churn = .hidden
    private(set) var isOpening = false
    private(set) var openError: String?
    private(set) var isClosed = false

    @ObservationIgnored let currentBranch: String?
    @ObservationIgnored let grouping: CommitDayGrouping
    @ObservationIgnored let locale: Locale
    @ObservationIgnored private let client: any RepoClient
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let open: @MainActor (CommitRange) -> Bool

    /// Bumped by every selection change and by `close()`; a read whose generation is
    /// stale publishes nothing.
    @ObservationIgnored private var generation = 0
    /// Exposed so tests can await it.
    @ObservationIgnored private(set) var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?
    /// The next read; a newer request replaces it rather than queueing behind it.
    @ObservationIgnored private var queued: Request?
    @ObservationIgnored private var running: Request?
    /// Runs queued reads one at a time. Exposed so tests can await it.
    @ObservationIgnored private(set) var readTask: Task<Void, Never>?
    /// Only a success is kept, so a retry after a failure reads again.
    @ObservationIgnored private var resolution: (generation: Int, range: CommitRange)?
    @ObservationIgnored private var waiters: [Waiter] = []

    static let debounceDelay = Duration.milliseconds(150)
    static let spinnerDelay = Duration.milliseconds(300)

    private struct Request {
        let generation: Int
        let base: GitRef
        let target: GitRef
    }

    private enum Resolution: Sendable {
        case range(CommitRange)
        case failed(String)
    }

    /// A submission waiting for the merge base; nil means the window closed.
    private struct Waiter {
        let generation: Int
        let continuation: CheckedContinuation<Resolution?, Never>
    }

    /// `open` returns false when the repository window is gone.
    init(
        client: any RepoClient, currentBranch: String?, clock: any Clock<Duration> = ContinuousClock(),
        grouping: CommitDayGrouping = CommitDayGrouping(), locale: Locale = .current,
        open: @escaping @MainActor (CommitRange) -> Bool
    ) {
        self.client = client
        self.currentBranch = currentBranch
        self.clock = clock
        self.grouping = grouping
        self.locale = locale
        self.open = open
    }

    // MARK: Loading

    func load() async {
        refList = .loading
        do {
            let loaded = try await client.refs()
            guard !isClosed else { return }
            refs = CompareRefOrdering.sorted(loaded, currentBranch: currentBranch)
            refList = .loaded
        } catch {
            guard !isClosed else { return }
            refList = .failed("Couldn't read branches and tags: \(error.localizedDescription)")
        }
    }

    /// Matches short names. The sort puts local branches before remote branches and tags,
    /// so a name both have picks the local branch.
    func load(selecting baseName: String?, _ targetName: String?) async {
        await load()
        if let ref = refs.first(where: { $0.name == baseName }) { select(ref, for: .base) }
        if let ref = refs.first(where: { $0.name == targetName }) { select(ref, for: .target) }
    }

    // MARK: Selection

    func selection(_ side: Side) -> GitRef? {
        switch side {
        case .base: base
        case .target: target
        }
    }

    func select(_ ref: GitRef, for side: Side) {
        guard !isOpening, selection(side) != ref else { return }
        switch side {
        case .base: base = ref
        case .target: target = ref
        }
        selectionChanged()
    }

    func clear(_ side: Side) {
        guard !isOpening, selection(side) != nil else { return }
        switch side {
        case .base: base = nil
        case .target: target = nil
        }
        selectionChanged()
    }

    func swap() {
        guard canSwap else { return }
        (base, target) = (target, base)
        selectionChanged()
    }

    /// Steps through the side's filtered rows; with nothing chosen there, starts at the first.
    func moveSelection(_ side: Side, by offset: Int) {
        let rows = rows(side)
        guard !rows.isEmpty else { return }
        let index =
            if let current = selection(side), let found = rows.firstIndex(of: current) {
                min(max(found + offset, 0), rows.count - 1)
            } else {
                0
            }
        select(rows[index], for: side)
    }

    var canCompare: Bool {
        guard let base, let target, !isOpening else { return false }
        return base.commitSHA != target.commitSHA
    }

    var canSwap: Bool {
        guard !isOpening, base != nil || target != nil else { return false }
        return !isTargetSameAsBase
    }

    var isTargetSameAsBase: Bool {
        guard let base, let target else { return false }
        return base.fullName == target.fullName
    }

    private func selectionChanged() {
        generation += 1
        debounceTask?.cancel()
        spinnerTask?.cancel()
        resolution = nil
        openError = nil
        guard let base, let target else {
            churn = .hidden
            queued = nil
            return
        }
        guard base.commitSHA != target.commitSHA else {
            churn = .noDifferences
            queued = nil
            return
        }
        churn = .pending
        let request = Request(generation: generation, base: base, target: target)
        debounceTask = Task { [weak self, clock] in
            do { try await Task.sleep(for: Self.debounceDelay, clock: clock) } catch { return }
            guard let self, generation == request.generation else { return }
            enqueue(request)
        }
        spinnerTask = Task { [weak self, clock] in
            do { try await Task.sleep(for: Self.spinnerDelay, clock: clock) } catch { return }
            guard let self, generation == request.generation, churn == .pending else { return }
            churn = .comparing
        }
    }

    // MARK: Reads

    private func enqueue(_ request: Request) {
        queued = request
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            await self?.drain()
            self?.readTask = nil
        }
    }

    private func drain() async {
        while let request = queued, !isClosed {
            queued = nil
            guard request.generation == generation else { continue }
            await run(request)
        }
    }

    private func isCurrent(_ request: Request) -> Bool {
        !isClosed && generation == request.generation
    }

    private func run(_ request: Request) async {
        running = request
        defer { running = nil }
        let mergeBase: String
        do {
            let found = try await client.mergeBase(request.base.commitSHA, request.target.commitSHA)
            guard isCurrent(request) else { return }
            guard let found else {
                fail(request, "\(request.base.name) and \(request.target.name) share no history")
                return
            }
            mergeBase = found
        } catch {
            guard isCurrent(request) else { return }
            fail(request, error.localizedDescription)
            return
        }
        let range = CommitRange(
            baseName: request.base.name, targetName: request.target.name, mergeBaseSHA: mergeBase,
            targetSHA: request.target.commitSHA)
        resolution = (request.generation, range)
        // A submission needs only the range; it opens without waiting for the counts.
        resumeWaiters(for: request.generation, with: .range(range))
        do {
            let summary = try await client.churn(base: mergeBase, target: request.target.commitSHA)
            guard isCurrent(request) else { return }
            publish(summary.fileCount == 0 ? .noDifferences : .ready(summary))
        } catch {
            guard isCurrent(request) else { return }
            publish(.failed(error.localizedDescription))
        }
    }

    /// Not cached: a retry reads the merge base again.
    private func fail(_ request: Request, _ message: String) {
        resumeWaiters(for: request.generation, with: .failed(message))
        publish(.failed(message))
    }

    private func publish(_ result: Churn) {
        spinnerTask?.cancel()
        churn = result
    }

    private func resumeWaiters(for generation: Int, with resolution: Resolution?) {
        let ready = waiters.filter { $0.generation == generation }
        waiters.removeAll { $0.generation == generation }
        for waiter in ready { waiter.continuation.resume(returning: resolution) }
    }

    // MARK: Submitting

    /// Opens the comparison tab once the merge base resolves; the preview counts are not
    /// awaited. True means the tab opened and the window should close.
    func submit() async -> Bool {
        guard canCompare, !isClosed, let base, let target else { return false }
        // Set before any suspension, so a second submit and selection changes are refused.
        isOpening = true
        openError = nil
        let generation = generation
        let outcome: Resolution?
        if let resolution, resolution.generation == generation {
            outcome = .range(resolution.range)
        } else {
            debounceTask?.cancel()
            if running?.generation != generation, queued?.generation != generation {
                enqueue(Request(generation: generation, base: base, target: target))
            }
            outcome = await withCheckedContinuation { continuation in
                waiters.append(Waiter(generation: generation, continuation: continuation))
            }
        }
        guard !isClosed, let outcome else { return false }
        switch outcome {
        case let .failed(message):
            openError = message
            isOpening = false
            return false
        case let .range(range):
            guard open(range) else {
                openError = "The repository window was closed."
                isOpening = false
                return false
            }
            return true
        }
    }

    /// Called when the window goes away: queued work is dropped and the results of reads
    /// already running are ignored (running git reads are not killed).
    func close() {
        isClosed = true
        generation += 1
        queued = nil
        resolution = nil
        debounceTask?.cancel()
        spinnerTask?.cancel()
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.continuation.resume(returning: nil) }
    }
}
