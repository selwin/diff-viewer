import Foundation
import Observation

/// What the Compare window's Branches mode compares: a base and a target ref.
struct BranchComparisonRequest: Sendable, Equatable {
    let base: GitRef
    let target: GitRef
}

/// What the Compare window shows and does. Branches mode has two filtered ref lists, the
/// chosen base and target, and a preview of each direction between them; Pull Request mode
/// is `pullRequest`. Either opens its range as a comparison tab.
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

    /// Forward compares the base with the target. Reverse is not the forward counts negated:
    /// it compares from its merge base to the base's tip, resolving that merge base itself.
    enum Direction {
        case forward
        case reverse
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
    /// Observed, so `swap()` exchanging them redraws the rows.
    private var forwardPreview: ComparisonPreview<BranchComparisonRequest>
    private var reversePreview: ComparisonPreview<BranchComparisonRequest>
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
        forwardPreview = Self.branchPreview(client: client, clock: clock)
        reversePreview = Self.branchPreview(client: client, clock: clock)
        pullRequest = PullRequestCompareModel(client: client, clock: clock)
    }

    private static func branchPreview(client: any RepoClient, clock: any Clock<Duration>)
        -> ComparisonPreview<BranchComparisonRequest>
    {
        // The stored resolver captures only the client, so the preview never retains the model.
        ComparisonPreview(client: client, clock: clock, debounce: debounceDelay, spinnerDelay: spinnerDelay) {
            request, _ in
            try await range(for: request, client: client)
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

    private func preview(_ direction: Direction) -> ComparisonPreview<BranchComparisonRequest> {
        switch direction {
        case .forward: forwardPreview
        case .reverse: reversePreview
        }
    }

    /// One direction's preview under the two wells. Two refs on one commit need no read; a
    /// pull request has no reverse.
    func churn(_ direction: Direction) -> ComparisonChurn {
        switch mode {
        case .branches:
            if let base, let target, base.commitSHA == target.commitSHA { return .noDifferences }
            return preview(direction).churn
        case .pullRequest:
            return direction == .forward ? pullRequest.churn : .hidden
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
    var debounceTask: Task<Void, Never>? { forwardPreview.debounceTask }
    var readTask: Task<Void, Never>? { forwardPreview.readTask }
    var reverseDebounceTask: Task<Void, Never>? { reversePreview.debounceTask }
    var reverseReadTask: Task<Void, Never>? { reversePreview.readTask }

    // MARK: Loading

    /// Reads the refs and the remotes together, then prefills the current branch against the
    /// default branch.
    func load() async {
        await load(initial: .automatic)
    }

    /// Matches short names. The sort puts local branches before remote branches and tags,
    /// so a name both have picks the local branch. A side with no name, or none found, stays
    /// empty, with no prefill.
    func load(selecting baseName: String?, _ targetName: String?) async {
        await load(initial: .explicit(base: baseName, target: targetName))
    }

    /// What `loadRefs` selects once the refs arrive.
    private enum InitialSelection {
        case automatic
        case explicit(base: String?, target: String?)
    }

    private func load(initial: InitialSelection) async {
        async let remotes: Void = pullRequest.loadRemotes()
        await loadRefs(initial: initial)
        await remotes
    }

    private func loadRefs(initial: InitialSelection) async {
        refList = .loading
        let client = client
        async let loadedRefs = client.refs()
        // Only the prefill uses the hint. A failed read is no hint: the local `main` or
        // `master` still applies.
        let wantsHint = if case .automatic = initial { true } else { false }
        async let originDefault = wantsHint ? try? await client.originDefaultBranchRef() : nil
        do {
            let loaded = try await loadedRefs
            let hint = await originDefault
            guard !isClosed else { return }
            // Refs, selection and `.loaded` land together, so the lists are never usable
            // before the prefill.
            refs = CompareRefOrdering.sorted(loaded, currentBranch: currentBranch)
            switch initial {
            case .automatic:
                let target = refs.first(where: isCurrentBranch)
                let base =
                    target == nil
                    ? nil : Self.defaultBase(in: refs, originDefaultBranchRef: hint, currentBranch: currentBranch)
                apply(base: base, target: target)
            case let .explicit(baseName, targetName):
                apply(base: refs.first { $0.name == baseName }, target: refs.first { $0.name == targetName })
            }
            refList = .loaded
        } catch {
            guard !isClosed else { return }
            refList = .failed("Couldn't read branches and tags: \(error.localizedDescription)")
        }
    }

    /// The branch a comparison against the current one starts from: origin's default branch
    /// (its local copy when there is one), else `main`, else `master`. Nil when that is the
    /// current branch, which would only compare it with itself.
    static func defaultBase(in refs: [GitRef], originDefaultBranchRef: String?, currentBranch: String?) -> GitRef? {
        func ref(_ fullName: String) -> GitRef? { refs.first { $0.fullName == fullName } }
        let originPrefix = "refs/remotes/origin/"
        var base: GitRef?
        if let hint = originDefaultBranchRef, hint.hasPrefix(originPrefix) {
            base = ref("refs/heads/" + hint.dropFirst(originPrefix.count)) ?? ref(hint)
        }
        guard let base = base ?? ref("refs/heads/main") ?? ref("refs/heads/master") else { return nil }
        return base.kind == .local && base.name == currentBranch ? nil : base
    }

    private func apply(base: GitRef?, target: GitRef?) {
        self.base = base
        self.target = target
        selectionChanged()
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

    /// The previews swap with the sides, so each keeps its request and its finished or
    /// running read, and nothing is read again.
    func swap() {
        guard canSwap else { return }
        (base, target) = (target, base)
        (forwardPreview, reversePreview) = (reversePreview, forwardPreview)
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

    /// Only a direction already known to be empty is refused. Submitting doesn't wait for
    /// the counts, so one submitted while they are pending can still open an empty tab.
    func canCompare(_ direction: Direction) -> Bool {
        guard !isOpening, churn(direction) != .noDifferences else { return false }
        switch mode {
        case .branches:
            guard let base, let target else { return false }
            return base.commitSHA != target.commitSHA
        case .pullRequest:
            return direction == .forward && pullRequest.canCompare
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
            forwardPreview.setRequest(nil)
            reversePreview.setRequest(nil)
            return
        }
        forwardPreview.setRequest(BranchComparisonRequest(base: base, target: target))
        reversePreview.setRequest(BranchComparisonRequest(base: target, target: base))
    }

    // MARK: Submitting

    /// Opens the direction's comparison tab once its merge base resolves; the preview counts
    /// are not awaited. True means the tab opened and the window should close.
    func submit(_ direction: Direction = .forward) async -> Bool {
        guard canCompare(direction), !isClosed else { return false }
        // Set before any suspension, so a second submit and selection changes are refused.
        isOpening = true
        openFailure = nil
        switch mode {
        case .branches:
            return finish(await preview(direction).resolvedRange(), generation: nil)
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
        forwardPreview.close()
        reversePreview.close()
        pullRequest.close()
    }
}
