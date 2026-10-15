import Foundation
import Observation

/// What the Compare window's Branches mode compares: a base and a target ref.
struct BranchComparisonRequest: Sendable, Equatable {
    let base: GitRef
    let target: GitRef
}

/// What the Compare window shows and does. Branches mode has two filtered ref lists, the
/// chosen base and target, and a preview of how much the target changed since their merge
/// base; Pull Request mode is `pullRequest`. Either opens its range as a comparison tab.
@MainActor
@Observable
final class CompareWindowModel {
    enum Mode {
        case branches
        case pullRequest
    }

    enum Side {
        case base
        case target
    }

    enum RefList: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// A Pull Request mode failure keeps the request generation it was for, so it hides once
    /// the input names another request, and stays hidden if the first is entered again.
    private struct OpenFailure {
        let message: String
        let generation: Int?
    }

    private(set) var mode = Mode.branches
    var baseQuery = ""
    var targetQuery = ""
    private(set) var refList: RefList = .loading
    /// Sorted once, by `CompareRefOrdering`.
    private(set) var refs: [GitRef] = []
    private(set) var base: GitRef?
    private(set) var target: GitRef?
    private(set) var isOpening = false
    private var openFailure: OpenFailure?
    private(set) var isClosed = false

    @ObservationIgnored let currentBranch: String?
    @ObservationIgnored let grouping: CommitDayGrouping
    @ObservationIgnored let locale: Locale
    @ObservationIgnored private let client: any RepoClient
    @ObservationIgnored private let open: @MainActor (CommitRange) -> Bool
    @ObservationIgnored private let branchPreview: ComparisonPreview<BranchComparisonRequest>
    /// Keeps its input and preview while Branches mode is shown.
    @ObservationIgnored let pullRequest: PullRequestCompareModel

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
        pullRequest = PullRequestCompareModel(client: client, clock: clock)
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
        switch mode {
        case .branches:
            if let base, let target, base.commitSHA == target.commitSHA { return .noDifferences }
            return branchPreview.churn
        case .pullRequest:
            return pullRequest.churn
        }
    }

    /// The footer's error, for the shown mode's current request.
    var openError: String? {
        guard let openFailure else { return nil }
        if mode == .pullRequest, openFailure.generation != pullRequest.requestGeneration { return nil }
        return openFailure.message
    }

    /// Refused while a submission is opening.
    func setMode(_ mode: Mode) {
        guard !isOpening else { return }
        openFailure = nil
        self.mode = mode
    }

    /// Exposed so tests can await them.
    var debounceTask: Task<Void, Never>? { branchPreview.debounceTask }
    var readTask: Task<Void, Never>? { branchPreview.readTask }

    // MARK: Loading

    /// Reads the refs and the remotes together.
    func load() async {
        async let remotes: Void = pullRequest.loadRemotes()
        await loadRefs()
        await remotes
    }

    private func loadRefs() async {
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
        guard !isOpening else { return false }
        switch mode {
        case .branches:
            guard let base, let target else { return false }
            return base.commitSHA != target.commitSHA
        case .pullRequest:
            return pullRequest.canCompare
        }
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
        openFailure = nil
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
        openFailure = nil
        switch mode {
        case .branches:
            return finish(await branchPreview.resolvedRange(), generation: nil)
        case .pullRequest:
            // Taken before awaiting, so a failure is kept with the request it was for.
            let generation = pullRequest.requestGeneration
            return finish(await pullRequest.resolvedRange(), generation: generation)
        }
    }

    /// `generation` is the pull request's request generation when submitted, or nil in Branches mode.
    private func finish(_ outcome: ComparisonOutcome?, generation: Int?) -> Bool {
        guard !isClosed else { return false }
        guard let outcome else {
            // The request changed or ended while opening, so Compare can be pressed again.
            isOpening = false
            return false
        }
        switch outcome {
        case let .failed(message):
            openFailure = OpenFailure(message: message, generation: generation)
            isOpening = false
            return false
        case let .range(range):
            guard open(range) else {
                openFailure = OpenFailure(message: "The repository window was closed.", generation: generation)
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
        pullRequest.close()
    }
}
