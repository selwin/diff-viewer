import Foundation
import Observation

/// What the Compare window's Branches mode compares: a base and a target ref.
struct BranchComparisonRequest: Sendable, Equatable {
    let base: GitRef
    let target: GitRef
}

/// What the Compare window shows and does: two filtered ref lists, the chosen base and
/// target, a preview of how much the target changed since their merge base, and opening
/// that range as a comparison tab. `ComparisonPreview` runs the reads.
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

    var baseQuery = ""
    var targetQuery = ""
    private(set) var refList: RefList = .loading
    /// Sorted once, by `CompareRefOrdering`.
    private(set) var refs: [GitRef] = []
    private(set) var base: GitRef?
    private(set) var target: GitRef?
    private(set) var isOpening = false
    private(set) var openError: String?
    private(set) var isClosed = false

    @ObservationIgnored let currentBranch: String?
    @ObservationIgnored let grouping: CommitDayGrouping
    @ObservationIgnored let locale: Locale
    @ObservationIgnored private let client: any RepoClient
    @ObservationIgnored private let open: @MainActor (CommitRange) -> Bool
    @ObservationIgnored private let branchPreview: ComparisonPreview<BranchComparisonRequest>

    static let debounceDelay = Duration.milliseconds(150)
    static let spinnerDelay = Duration.milliseconds(300)

    /// `open` returns false when the repository window is gone.
    init(
        client: any RepoClient, currentBranch: String?, clock: any Clock<Duration> = ContinuousClock(),
        grouping: CommitDayGrouping = CommitDayGrouping(), locale: Locale = .current,
        open: @escaping @MainActor (CommitRange) -> Bool
    ) {
        self.client = client
        self.currentBranch = currentBranch
        self.grouping = grouping
        self.locale = locale
        self.open = open
        // The stored resolver captures only the client, so the preview never retains the model.
        branchPreview = ComparisonPreview(
            client: client, clock: clock, debounce: Self.debounceDelay, spinnerDelay: Self.spinnerDelay
        ) { request, _ in
            try await Self.range(for: request, client: client)
        }
    }

    private static func range(for request: BranchComparisonRequest, client: any RepoClient) async throws
        -> CommitRange
    {
        guard let mergeBase = try await client.mergeBase(request.base.commitSHA, request.target.commitSHA) else {
            throw ComparisonFailure("\(request.base.name) and \(request.target.name) share no history")
        }
        return CommitRange(
            baseName: request.base.name, targetName: request.target.name, mergeBaseSHA: mergeBase,
            targetSHA: request.target.commitSHA)
    }

    /// The preview under the two wells. Two refs on one commit need no read.
    var churn: ComparisonChurn {
        if let base, let target, base.commitSHA == target.commitSHA { return .noDifferences }
        return branchPreview.churn
    }

    /// Exposed so tests can await them.
    var debounceTask: Task<Void, Never>? { branchPreview.debounceTask }
    var readTask: Task<Void, Never>? { branchPreview.readTask }

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
        openError = nil
        guard let base, let target, base.commitSHA != target.commitSHA else {
            branchPreview.setRequest(nil)
            return
        }
        branchPreview.setRequest(BranchComparisonRequest(base: base, target: target))
    }

    // MARK: Submitting

    /// Opens the comparison tab once the merge base resolves; the preview counts are not
    /// awaited. True means the tab opened and the window should close.
    func submit() async -> Bool {
        guard canCompare, !isClosed else { return false }
        // Set before any suspension, so a second submit and selection changes are refused.
        isOpening = true
        openError = nil
        let outcome = await branchPreview.resolvedRange()
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
        branchPreview.close()
    }
}
