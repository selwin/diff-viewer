import Foundation

@testable import DiffViewer

/// A stub call a test can hold open. A held call records itself before it parks, so a
/// test can count a call that is still waiting.
enum StubCall {
    case status
    case numstat
    /// `numstatAgainstHead`, a conflict's counts.
    case headNumstat
    /// `perform`, `trash` and `commit`, so a write can be queued behind one still running.
    case actions
    /// Worktree reads; per-path holds are separate.
    case reads
    case commitFiles
    case head
    case history
    case localBranches
    case switchBranch
    case remoteNames
    case fetch
    case pull
    case push
    case publish
    case fastForward
    case commitDefaults
    case stagedPatch
    case mergePreview
    case incomingChanges
    case stashes
    /// `stash`, `pop` and `drop`.
    case stashActions
    /// `contents(of:at:)`, a commit or range side.
    case revisionReads
    /// `changedFiles(in:)` for a range.
    case rangeFiles
    case refs
    case mergeBase
    case churn
    case remotes
    case advertisedPullRequest
    case fetchPullRequest
    case pinPullRequest
    case pullRequestBase
}

/// The calls parked on one `StubCall`, and whether new ones park too.
struct CallGate {
    var holds = false
    var waiters: [CheckedContinuation<Void, Never>] = []

    var count: Int { waiters.count }

    mutating func releaseAll() {
        let waiting = waiters
        waiters = []
        for continuation in waiting { continuation.resume() }
    }

    /// The oldest, so completion order can be chosen.
    mutating func releaseFirst() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
    /// The newest, for the other half of that choice.
    mutating func releaseLast() { if !waiters.isEmpty { waiters.removeLast().resume() } }
}

/// A repository whose calls can be held open and released.
actor StubRepoClient: RepoClient {
    private var files: [ChangedFile]
    private var fails = false
    private var gates: [StubCall: CallGate] = [:]
    private(set) var statusCalls = 0
    /// Worktree paths whose read suspends until the test releases them.
    private var heldPaths: Set<String> = []
    private var pathWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Worktree paths whose read throws rather than returning contents.
    private var failingWorktreePaths: Set<String> = []
    /// Content reads of any kind since creation.
    private(set) var contentReads = 0
    /// Every path read, in order, whichever side it was read from.
    private(set) var readPaths: [String] = []
    /// Content reads running at once, and the most there have ever been.
    private(set) var inFlightReads = 0
    private(set) var peakInFlightReads = 0
    private var numstatEntries: [ChangedFile.Area: [NumstatEntry]] = [:]
    private var failsNumstat = false
    /// The `ignoreWhitespace` argument of the most recent numstat call.
    private(set) var lastIgnoreWhitespace: Bool?
    private(set) var numstatCalls = 0
    /// Rows for `numstatAgainstHead`, filtered to the paths asked for. Nil, the default,
    /// makes it throw, for the same reason an unconfigured numstat area does.
    private var headNumstatEntries: [NumstatEntry]?
    /// The paths of every `numstatAgainstHead` call, in order.
    private(set) var headNumstatCalls: [[String]] = []
    /// Worktree contents by path, overriding the default "new \(path)" body.
    private var worktree: [String: Data?] = [:]
    /// Index bytes by path; an unlisted path gets the stub's fixed text.
    private var index: [String: Data] = [:]
    /// Blob bytes by object id. An unlisted id is one git cannot produce, so the engine
    /// falls back to the path read and never registers the result.
    private var blobs: [String: Data] = [:]
    /// Every `blobContents` call, in order. Kept out of `contentReads`, which counts path reads.
    private(set) var blobReads: [String] = []
    /// What `worktreeState` answers by path. Unlisted is `.unknown`, which matches no
    /// fingerprint, so a worktree read is never registered unless a test says so.
    private var worktreeStates: [String: DiffInputFingerprint.Worktree] = [:]
    /// Object sizes by spec; an unlisted spec is one git has no object for.
    private var objectSizesBySpec: [String: Int64] = [:]
    private var failsObjectSizes = false
    private var truncatesObjectSizes = false
    /// Every `objectSizes` batch asked for, in order.
    private(set) var objectSizesCalls: [[String]] = []
    private var head: String? = String(repeating: "a", count: 40)
    private var stubbedHeadState: HeadState = .named("main")
    private var failsHeadState = false
    private(set) var headStateCalls = 0
    private var stubbedLocalBranches: [LocalBranch] = [localBranch("main")]
    private var failsLocalBranches = false
    private(set) var localBranchesCalls = 0
    private var stubbedRemoteBranches: [RemoteBranch] = []
    private var failsRemoteBranches = false
    private(set) var remoteBranchesCalls = 0
    /// Every remote checkout asked for, in order, whether or not it succeeded.
    private(set) var checkoutTrackingCalls: [(branch: String, trackingRef: String)] = []
    private var failsCheckoutTracking = false
    /// Every branch creation asked for, in order, whether or not it succeeded.
    private(set) var createBranchCalls: [String] = []
    private var failsCreateBranch = false
    /// Every branch a switch was asked for, in order, whether or not it succeeded.
    private(set) var switchBranchCalls: [String] = []
    /// Every branch a delete was asked for, in order, whether or not it succeeded.
    private(set) var deleteBranchCalls: [String] = []
    private var failsDeleteBranch = false
    private var stubbedRemoteNames: [String] = ["origin"]
    private(set) var remoteNamesCalls = 0
    private(set) var fetchCalls: [String] = []
    private(set) var pullCalls = 0
    /// Every push asked for, in order, whether or not it succeeded.
    private(set) var pushCalls: [(branch: String, remote: String, remoteRef: String)] = []
    /// Every publish asked for, in order, whether or not it succeeded.
    private(set) var publishCalls: [(branch: String, remote: String)] = []
    /// Every fast-forward asked for, in order, whether or not it succeeded.
    private(set) var fastForwardCalls: [(branch: String, remote: String, remoteRef: String, localRef: String)] = []
    private var stubbedMergePreview: MergePreview = .alreadyMerged
    /// Per-key answers on top of `stubbedMergePreview`.
    private var mergePreviewsByKey: [MergePreviewKey: MergePreview] = [:]
    private var failingMergePreviews: Set<MergePreviewKey> = []
    /// Every `mergePreview` call, in order.
    private(set) var mergePreviewCalls: [MergePreviewKey] = []
    private var stubbedIncomingChanges = IncomingChangeSummary(fileCount: 0, addedLineCount: 0, deletedLineCount: 0)
    private var failsIncomingChanges = false
    /// Every `incomingChanges` call, in order.
    private(set) var incomingChangesCalls: [MergePreviewKey] = []
    private var stubbedRefs: [GitRef] = []
    private var failsRefs = false
    /// Merge bases keyed by the two SHAs asked about, in the order asked; unlisted pairs have none.
    private var mergeBases: [RevisionPair: String] = [:]
    private var failsMergeBase = false
    /// Every `mergeBase` and `churn` call's arguments, in order.
    private(set) var mergeBaseRequests: [RevisionPair] = []
    var mergeBaseCalls: Int { mergeBaseRequests.count }
    private var stubbedChurn = IncomingChangeSummary(fileCount: 0, addedLineCount: 0, deletedLineCount: 0)
    private var failsChurn = false
    private(set) var churnRequests: [RevisionPair] = []
    var churnCalls: Int { churnRequests.count }
    private var stubbedRemotes: [GitRemote] = []
    private var stubbedAdvertised: AdvertisedPullRequest?
    private var stubbedPullRequestBase = PullRequestComparisonBase(commitSHA: objectID("pr-base"), isRecovered: false)
    /// The error each pull request call throws, after recording itself and any hold.
    private var pullRequestErrors: [StubCall: any Error] = [:]
    private(set) var remotesCalls = 0
    private(set) var advertisedPullRequestCalls: [(number: Int, remote: String)] = []
    private(set) var fetchPullRequestCalls: [AdvertisedPullRequest] = []
    private(set) var pinPullRequestCalls: [AdvertisedPullRequest] = []
    private(set) var pullRequestBaseRequests: [(headSHA: String, baseTipSHA: String)] = []
    private(set) var runningMergePreviews = 0
    private(set) var mostRunningMergePreviews = 0
    struct MergeCall: Equatable {
        let sourceTipSha: String
        let sourceRef: String
    }
    /// Every merge asked for, in order, whether or not it succeeded.
    private(set) var mergeCalls: [MergeCall] = []
    private var failsMerge = false
    private var stubbedUpstreamRemotes: [String: String] = [:]
    private var failsConfiguredUpstreamRemotes = false
    private var failsFetch = false
    /// Per-remote holds and failures, on top of the switches above.
    private var heldFetchRemotes: Set<String> = []
    private var failingFetchRemotes: Set<String> = []
    private var failsRemoteNames = false
    private var failsPull = false
    private var failsPush = false
    private var failsPublish = false
    private var failsFastForward = false
    private var failsSwitchBranch = false
    /// What HEAD becomes once a switch runs, even one that then fails: a post-checkout
    /// hook fails after git has already moved HEAD. Nil leaves the state alone.
    private var headStateAfterSwitch: HeadState?
    private var headAfterSwitch: String??
    private var commits: [CommitSummary] = []
    /// Files each commit changed, by sha.
    private var commitFiles: [String: [ChangedFile]] = [:]
    private var failsHistory = false
    private var failsCommitFiles = false
    private var rangeFiles: [ChangedFile] = []
    private var failsRangeFiles = false
    private(set) var headCalls = 0
    private(set) var historyCalls = 0
    private(set) var lastHistoryRevision: String?
    private(set) var lastHistoryLimit: Int?
    private(set) var lastHistorySkip: Int?
    /// What `commitSha(of:)` answers per ref; an unlisted ref names no commit, except that
    /// a `refs/heads/` ref falls back to that local branch's tip.
    private var stubbedCommitShas: [String: String] = [:]
    private var failsCommitSha = false
    /// Every ref `commitSha(of:)` was asked to resolve, in order.
    private(set) var commitShaCalls: [String] = []
    private var stubbedStashes: [StashEntry] = []
    private var failsStashes = false
    private(set) var stashesCalls = 0
    /// Every entry `pop` or `drop` was asked for, in order, whether or not it succeeded.
    private(set) var popCalls: [StashEntry] = []
    private(set) var dropCalls: [StashEntry] = []
    /// Every `stash` push asked for, in order, whether or not it succeeded.
    private(set) var stashPushCalls: [StashPushCall] = []
    private var stashActionError: (any Error)?
    private var filesAfterPop: [ChangedFile]?
    private var stubbedUnpushed: Set<String> = []
    private var failsUnpushed = false
    /// Every `unpushedCommits` read, in order.
    private(set) var unpushedCalls: [(tip: String, upstreamTip: String)] = []
    private(set) var commitFileCalls = 0
    /// Every `(path, revision)` pair `contents(of:at:)` was asked for, in order.
    private(set) var contentRevisions: [(path: String, revision: String)] = []
    /// Every git write asked for, in order: one entry per call, holding the whole batch.
    private(set) var performed: [(action: GitFileAction, paths: [String])] = []
    /// Every trash call, in order: one entry per call, holding the whole batch.
    private(set) var trashed: [[String]] = []
    private var failsActions = false
    /// What the repository becomes once a write succeeds, standing in for git's own
    /// effect on it. Nil leaves `files` alone.
    private var filesAfterWrite: [ChangedFile]?
    /// Every message a commit was asked for, in order, whether or not it succeeded.
    private(set) var commitMessages: [String] = []
    private var stubbedDefaults = CommitDefaults.none
    private var failsCommit = false
    private var failsCommitDefaults = false
    private(set) var commitDefaultsCalls = 0
    private var stubbedStagedPatch = ""
    private var stubbedStagedPatches: [Int: String] = [:]
    /// The context size of every staged patch asked for, in order.
    private(set) var stagedPatchContextLines: [Int] = []

    init(files: [ChangedFile]) { self.files = files }

    func set(files: [ChangedFile]) { self.files = files }
    /// The list `status()` reports from the moment a `perform` or `trash` completes, so
    /// a test says what the write did to the repository instead of pre-seeding a status
    /// read that the write's own validation would see too early.
    func set(filesAfterWrite list: [ChangedFile]?) { filesAfterWrite = list }
    var currentFiles: [ChangedFile] { files }
    func fail(_ on: Bool) { fails = on }

    func set(numstat entries: [NumstatEntry], area: ChangedFile.Area) { numstatEntries[area] = entries }
    func fail(numstat on: Bool) { failsNumstat = on }
    /// Nil makes `numstatAgainstHead` throw.
    func set(headNumstat entries: [NumstatEntry]?) { headNumstatEntries = entries }
    /// Makes both `perform` and `trash` throw, after recording the call.
    func fail(actions on: Bool) { failsActions = on }
    func set(worktree data: Data?, for path: String) { worktree[path] = .some(data) }
    func set(index data: Data, for path: String) { index[path] = data }
    func set(blob data: Data?, for oid: String) { blobs[oid] = data }
    func set(worktreeState state: DiffInputFingerprint.Worktree, for path: String) { worktreeStates[path] = state }
    /// The size `objectSizes` answers for `spec`; nil is what git says for a missing object.
    func set(objectSize size: Int64?, for spec: String) { objectSizesBySpec[spec] = size }
    /// Makes `objectSizes` throw, after recording the call.
    func fail(objectSizes on: Bool) { failsObjectSizes = on }
    /// Makes `objectSizes` answer one entry short, after recording the call.
    func truncate(objectSizes on: Bool) { truncatesObjectSizes = on }

    func objectSizes(of specs: [String]) async throws -> [Int64?] {
        objectSizesCalls.append(specs)
        if failsObjectSizes {
            throw ProcessError.failed(command: "git cat-file", status: 128, stderr: "gone")
        }
        let sizes = specs.map { objectSizesBySpec[$0] }
        return truncatesObjectSizes ? Array(sizes.dropLast()) : sizes
    }

    func numstat(area: ChangedFile.Area, ignoreWhitespace: Bool) async throws -> [NumstatEntry] {
        numstatCalls += 1
        lastIgnoreWhitespace = ignoreWhitespace
        if isHeld(.numstat) { await park(.numstat) }
        // An area no test configured is unknown, not empty: the joiner treats an empty
        // list as "git saw no churn" and would stamp every file with +0 −0.
        guard !failsNumstat, let entries = numstatEntries[area] else {
            throw ProcessError.failed(command: "git diff --numstat", status: 128, stderr: "gone")
        }
        return entries
    }

    func numstatAgainstHead(paths: [String], ignoreWhitespace: Bool) async throws -> [NumstatEntry] {
        headNumstatCalls.append(paths)
        if isHeld(.headNumstat) { await park(.headNumstat) }
        guard let entries = headNumstatEntries else {
            throw ProcessError.failed(command: "git diff HEAD --numstat", status: 128, stderr: "gone")
        }
        return entries.filter { paths.contains($0.path) }
    }

    func status() async throws -> [ChangedFile] {
        statusCalls += 1
        let snapshot = files
        if isHeld(.status) { await park(.status) }
        if fails { throw ProcessError.failed(command: "git status", status: 128, stderr: "gone") }
        return snapshot
    }

    // MARK: Holding calls

    /// Makes later `call`s park until released; calls already parked stay parked.
    func hold(_ call: StubCall, _ on: Bool = true) { gates[call, default: CallGate()].holds = on }
    func heldCount(_ call: StubCall) -> Int { gates[call]?.count ?? 0 }
    func release(_ call: StubCall) { gates[call]?.releaseAll() }
    func releaseFirst(_ call: StubCall) { gates[call]?.releaseFirst() }
    func releaseLast(_ call: StubCall) { gates[call]?.releaseLast() }

    private func isHeld(_ call: StubCall) -> Bool { gates[call]?.holds ?? false }

    /// Appends inside the closure: actor storage cannot be held across the suspension.
    private func park(_ call: StubCall) async {
        await withCheckedContinuation { gates[call, default: CallGate()].waiters.append($0) }
    }

    // MARK: Per-path worktree reads

    /// Suspends the worktree read of each path until it is released, so one file's diff
    /// can be held open while the others finish.
    func hold(worktree paths: Set<String>) { heldPaths.formUnion(paths) }
    /// The paths whose reads are suspended right now.
    var waitingWorktreePaths: Set<String> { Set(pathWaiters.keys) }
    func release(worktree path: String) {
        heldPaths.remove(path)
        for continuation in pathWaiters.removeValue(forKey: path) ?? [] { continuation.resume() }
    }
    func releaseAllWorktreeHolds() {
        heldPaths.removeAll()
        let waiting = pathWaiters
        pathWaiters = [:]
        for continuation in waiting.values.flatMap({ $0 }) { continuation.resume() }
    }
    /// Paths whose worktree read throws: a file that is there but cannot be read.
    func fail(worktree paths: Set<String>) { failingWorktreePaths = paths }

    private func beginRead(_ path: String) {
        contentReads += 1
        readPaths.append(path)
        inFlightReads += 1
        peakInFlightReads = max(peakInFlightReads, inFlightReads)
    }

    private func endRead() { inFlightReads -= 1 }

    // MARK: History and commits

    func set(head sha: String?) { head = sha }
    func set(headState state: HeadState) { stubbedHeadState = state }
    func fail(headState on: Bool) { failsHeadState = on }
    func set(commits list: [CommitSummary]) { commits = list }
    func set(files list: [ChangedFile], forCommit sha: String) { commitFiles[sha] = list }
    func fail(history on: Bool) { failsHistory = on }
    func fail(commitFiles on: Bool) { failsCommitFiles = on }
    func set(rangeFiles list: [ChangedFile]) { rangeFiles = list }
    func fail(rangeFiles on: Bool) { failsRangeFiles = on }

    func headSha() async throws -> String? {
        headCalls += 1
        // Snapshot before suspending, the way `status()` does: a held read must report
        // the revision it was asked about, not whatever HEAD became while it waited.
        let snapshot = head
        if isHeld(.head) { await park(.head) }
        if failsHistory { throw ProcessError.failed(command: "git rev-parse", status: 128, stderr: "gone") }
        return snapshot
    }

    func headState() async throws -> HeadState {
        headStateCalls += 1
        if failsHeadState { throw ProcessError.failed(command: "git symbolic-ref", status: 128, stderr: "gone") }
        return stubbedHeadState
    }

    // MARK: Branches

    /// Plain names, for the tests that only care about the list the picker shows.
    func set(localBranches names: [String]) {
        stubbedLocalBranches = names.map { localBranch($0) }
    }
    func set(localBranches branches: [LocalBranch]) { stubbedLocalBranches = branches }
    func fail(localBranches on: Bool) { failsLocalBranches = on }

    func set(remoteBranches branches: [RemoteBranch]) { stubbedRemoteBranches = branches }
    func fail(remoteBranches on: Bool) { failsRemoteBranches = on }
    /// Makes `checkoutTracking` throw, after recording the call.
    func fail(checkoutTracking on: Bool) { failsCheckoutTracking = on }

    /// Makes `switchBranch` throw, after recording the call and moving HEAD.
    func fail(switchBranch on: Bool) { failsSwitchBranch = on }
    /// Makes `deleteBranch` throw, after recording the call.
    func fail(deleteBranch on: Bool) { failsDeleteBranch = on }

    /// The head state a switch leaves behind, applied whether or not the switch fails.
    func set(headStateAfterSwitch state: HeadState?) { headStateAfterSwitch = state }
    /// The head sha a switch leaves behind, applied whether or not the switch fails.
    func set(headAfterSwitch sha: String?) { headAfterSwitch = .some(sha) }

    func localBranches() async throws -> [LocalBranch] {
        localBranchesCalls += 1
        // Snapshot before suspending, the way `status()` does: a held read reports what
        // the repository looked like when it was asked.
        let snapshot = stubbedLocalBranches
        if isHeld(.localBranches) { await park(.localBranches) }
        if failsLocalBranches {
            throw ProcessError.failed(command: "git for-each-ref", status: 128, stderr: "gone")
        }
        return snapshot
    }

    func remoteBranches() async throws -> [RemoteBranch] {
        remoteBranchesCalls += 1
        if failsRemoteBranches {
            throw ProcessError.failed(command: "git for-each-ref", status: 128, stderr: "gone")
        }
        return stubbedRemoteBranches
    }

    /// Adds the tracking branch and moves HEAD onto it on success, as git would.
    func checkoutTracking(branch: String, trackingRef: String) async throws {
        checkoutTrackingCalls.append((branch: branch, trackingRef: trackingRef))
        if failsCheckoutTracking {
            throw ProcessError.failed(command: "git switch", status: 128, stderr: "checkout failed")
        }
        let shortName = String(trackingRef.dropFirst("refs/remotes/".count))
        stubbedLocalBranches.append(localBranch(branch, upstream: upstream(shortName, localRef: trackingRef)))
        stubbedHeadState = .named(branch)
    }

    /// Makes `createBranch` throw, after recording the call.
    func fail(createBranch on: Bool) { failsCreateBranch = on }

    /// Adds the branch and moves HEAD onto it on success, as git would.
    func createBranch(_ name: String) async throws {
        createBranchCalls.append(name)
        if failsCreateBranch {
            throw ProcessError.failed(command: "git switch", status: 128, stderr: "create failed")
        }
        stubbedLocalBranches.append(localBranch(name))
        stubbedHeadState = .named(name)
    }

    /// Only the leading-dash rule; git's own rules are covered by `GitCommandTests`.
    func isValidBranchName(_ name: String) async throws -> Bool { !name.hasPrefix("-") }

    func switchBranch(to branch: String) async throws {
        switchBranchCalls.append(branch)
        if isHeld(.switchBranch) { await park(.switchBranch) }
        // HEAD moves before the failure check: a post-checkout hook fails after git has
        // already switched, and that is the case a caller has to refresh through.
        if let headStateAfterSwitch { stubbedHeadState = headStateAfterSwitch }
        if let headAfterSwitch { head = headAfterSwitch }
        if failsSwitchBranch {
            throw ProcessError.failed(command: "git switch", status: 1, stderr: "post-checkout hook failed")
        }
    }

    /// Removes the branch from the list on success, as git would.
    func deleteBranch(_ name: String) async throws {
        deleteBranchCalls.append(name)
        if failsDeleteBranch {
            throw ProcessError.failed(command: "git branch -D", status: 1, stderr: "delete failed")
        }
        stubbedLocalBranches.removeAll { $0.name == name }
    }

    // MARK: Remotes

    func set(remoteNames names: [String]) { stubbedRemoteNames = names }
    /// Makes `fetch` throw, after recording the call.
    func fail(fetch on: Bool) { failsFetch = on }
    /// Makes `fetch` of one remote throw.
    func fail(fetch on: Bool, remote: String) {
        if on { failingFetchRemotes.insert(remote) } else { failingFetchRemotes.remove(remote) }
    }
    func fail(pull on: Bool) { failsPull = on }
    func fail(push on: Bool) { failsPush = on }
    func fail(publish on: Bool) { failsPublish = on }
    func fail(fastForward on: Bool) { failsFastForward = on }
    func set(mergePreview preview: MergePreview) { stubbedMergePreview = preview }
    func set(mergePreview preview: MergePreview, for key: MergePreviewKey) { mergePreviewsByKey[key] = preview }
    /// Read once a held call is released, so a test can change it meanwhile.
    func fail(mergePreview on: Bool, for key: MergePreviewKey) {
        if on { failingMergePreviews.insert(key) } else { failingMergePreviews.remove(key) }
    }
    func set(incomingChanges summary: IncomingChangeSummary) { stubbedIncomingChanges = summary }
    /// Read once a held call is released, so a test can change it meanwhile.
    func fail(incomingChanges on: Bool) { failsIncomingChanges = on }
    func fail(merge on: Bool) { failsMerge = on }
    func set(refs list: [GitRef]) { stubbedRefs = list }
    func fail(refs on: Bool) { failsRefs = on }
    func set(mergeBase sha: String?, for first: String, _ second: String) {
        mergeBases[RevisionPair(baseSHA: first, targetSHA: second)] = sha
    }
    /// The merge base, churn and their failures are read once a held call is released,
    /// so a test can change them meanwhile.
    func fail(mergeBase on: Bool) { failsMergeBase = on }
    func set(churn summary: IncomingChangeSummary) { stubbedChurn = summary }
    func fail(churn on: Bool) { failsChurn = on }
    func set(remotes list: [GitRemote]) { stubbedRemotes = list }
    /// What `advertisedPullRequest` answers; unset, it answers a default branch `main` and
    /// fixed SHAs for whatever number and remote it is asked about.
    func set(advertised: AdvertisedPullRequest?) { stubbedAdvertised = advertised }
    func set(pullRequestBase base: PullRequestComparisonBase) { stubbedPullRequestBase = base }
    /// Makes `call` throw `error`, or stop throwing with nil. Covers `.remotes`,
    /// `.advertisedPullRequest`, `.fetchPullRequest`, `.pinPullRequest` and `.pullRequestBase`;
    /// read once a held call is released, so a test can change it meanwhile.
    func fail(_ call: StubCall, with error: (any Error)?) { pullRequestErrors[call] = error }
    func set(configuredUpstreamRemotes remotes: [String: String]) { stubbedUpstreamRemotes = remotes }
    func fail(configuredUpstreamRemotes on: Bool) { failsConfiguredUpstreamRemotes = on }

    /// Makes `remoteNames` throw, after recording the call.
    func fail(remoteNames on: Bool) { failsRemoteNames = on }
    /// Suspends `fetch` of one remote on the fetch gate; `release(.fetch)` lets it go.
    func holdFetch(_ on: Bool, remote: String) {
        if on { heldFetchRemotes.insert(remote) } else { heldFetchRemotes.remove(remote) }
    }

    func remoteNames() async throws -> [String] {
        remoteNamesCalls += 1
        let snapshot = stubbedRemoteNames
        if isHeld(.remoteNames) { await park(.remoteNames) }
        if failsRemoteNames {
            throw ProcessError.failed(command: "git remote", status: 128, stderr: "no remotes")
        }
        return snapshot
    }

    func fetch(remote: String) async throws {
        fetchCalls.append(remote)
        if isHeld(.fetch) || heldFetchRemotes.contains(remote) { await park(.fetch) }
        if failsFetch || failingFetchRemotes.contains(remote) {
            throw ProcessError.failed(command: "git fetch", status: 1, stderr: "fetch failed")
        }
    }

    func pull() async throws {
        pullCalls += 1
        if isHeld(.pull) { await park(.pull) }
        if failsPull { throw ProcessError.failed(command: "git pull", status: 1, stderr: "pull failed") }
    }

    func push(branch: String, to remote: String, remoteRef: String) async throws {
        pushCalls.append((branch: branch, remote: remote, remoteRef: remoteRef))
        if isHeld(.push) { await park(.push) }
        if failsPush { throw ProcessError.failed(command: "git push", status: 1, stderr: "push failed") }
    }

    func publish(branch: String, to remote: String) async throws {
        publishCalls.append((branch: branch, remote: remote))
        if isHeld(.publish) { await park(.publish) }
        if failsPublish { throw ProcessError.failed(command: "git push", status: 1, stderr: "publish failed") }
    }

    func fastForward(branch: String, remote: String, remoteRef: String, localRef: String) async throws {
        fastForwardCalls.append((branch: branch, remote: remote, remoteRef: remoteRef, localRef: localRef))
        if isHeld(.fastForward) { await park(.fastForward) }
        if failsFastForward {
            throw ProcessError.failed(command: "git fetch", status: 1, stderr: "fast-forward failed")
        }
    }

    func mergePreview(headSha: String, sourceTipSha: String) async throws -> MergePreview {
        let key = MergePreviewKey(headSha: headSha, sourceTipSha: sourceTipSha)
        mergePreviewCalls.append(key)
        runningMergePreviews += 1
        mostRunningMergePreviews = max(mostRunningMergePreviews, runningMergePreviews)
        defer { runningMergePreviews -= 1 }
        if isHeld(.mergePreview) { await park(.mergePreview) }
        if failingMergePreviews.contains(key) {
            throw ProcessError.failed(command: "git merge-tree", status: 128, stderr: "unrelated histories")
        }
        return mergePreviewsByKey[key] ?? stubbedMergePreview
    }

    func incomingChanges(headSha: String, sourceTipSha: String) async throws -> IncomingChangeSummary {
        incomingChangesCalls.append(MergePreviewKey(headSha: headSha, sourceTipSha: sourceTipSha))
        if isHeld(.incomingChanges) { await park(.incomingChanges) }
        if failsIncomingChanges {
            throw ProcessError.failed(command: "git diff", status: 128, stderr: "no merge base")
        }
        return stubbedIncomingChanges
    }

    func refs() async throws -> [GitRef] {
        if isHeld(.refs) { await park(.refs) }
        if failsRefs { throw ProcessError.failed(command: "git for-each-ref", status: 128, stderr: "gone") }
        return stubbedRefs
    }

    func mergeBase(_ first: String, _ second: String) async throws -> String? {
        mergeBaseRequests.append(RevisionPair(baseSHA: first, targetSHA: second))
        if isHeld(.mergeBase) { await park(.mergeBase) }
        if failsMergeBase {
            throw ProcessError.failed(command: "git merge-base", status: 128, stderr: "bad object")
        }
        return mergeBases[RevisionPair(baseSHA: first, targetSHA: second)]
    }

    func churn(base: String, target: String) async throws -> IncomingChangeSummary {
        churnRequests.append(RevisionPair(baseSHA: base, targetSHA: target))
        if isHeld(.churn) { await park(.churn) }
        if failsChurn { throw ProcessError.failed(command: "git diff", status: 128, stderr: "gone") }
        return stubbedChurn
    }

    func remotes() async throws -> [GitRemote] {
        remotesCalls += 1
        let snapshot = stubbedRemotes
        if isHeld(.remotes) { await park(.remotes) }
        if let error = pullRequestErrors[.remotes] { throw error }
        return snapshot
    }

    func advertisedPullRequest(number: Int, remote: String) async throws -> AdvertisedPullRequest {
        advertisedPullRequestCalls.append((number, remote))
        let snapshot =
            stubbedAdvertised
            ?? AdvertisedPullRequest(
                remote: remote, number: number, defaultBranch: "main", baseTipSHA: objectID("pr-base-tip"),
                headSHA: objectID("pr-head"))
        if isHeld(.advertisedPullRequest) { await park(.advertisedPullRequest) }
        if let error = pullRequestErrors[.advertisedPullRequest] { throw error }
        return snapshot
    }

    func fetchPullRequest(_ advertised: AdvertisedPullRequest) async throws {
        fetchPullRequestCalls.append(advertised)
        if isHeld(.fetchPullRequest) { await park(.fetchPullRequest) }
        if let error = pullRequestErrors[.fetchPullRequest] { throw error }
    }

    func pinAdvertisedCommits(_ advertised: AdvertisedPullRequest) async throws {
        pinPullRequestCalls.append(advertised)
        if isHeld(.pinPullRequest) { await park(.pinPullRequest) }
        if let error = pullRequestErrors[.pinPullRequest] { throw error }
    }

    func pullRequestBase(headSHA: String, baseTipSHA: String) async throws -> PullRequestComparisonBase {
        pullRequestBaseRequests.append((headSHA, baseTipSHA))
        if isHeld(.pullRequestBase) { await park(.pullRequestBase) }
        if let error = pullRequestErrors[.pullRequestBase] { throw error }
        return stubbedPullRequestBase
    }

    func merge(sourceTipSha: String, sourceRef: String) async throws {
        mergeCalls.append(MergeCall(sourceTipSha: sourceTipSha, sourceRef: sourceRef))
        if failsMerge { throw ProcessError.failed(command: "git merge", status: 1, stderr: "merge failed") }
    }

    func configuredUpstreamRemotes() async throws -> [String: String] {
        if failsConfiguredUpstreamRemotes {
            throw ProcessError.failed(command: "git config", status: 2, stderr: "config failed")
        }
        return stubbedUpstreamRemotes
    }

    func recentCommits(startingAt revision: String, skip: Int, limit: Int) async throws -> [CommitSummary] {
        historyCalls += 1
        lastHistoryRevision = revision
        lastHistorySkip = skip
        lastHistoryLimit = limit
        let snapshot = commits
        if isHeld(.history) { await park(.history) }
        if failsHistory { throw ProcessError.failed(command: "git log", status: 128, stderr: "gone") }
        return Array(snapshot.dropFirst(skip).prefix(limit))
    }

    // MARK: Unpushed commits

    func set(commitSha sha: String?, for ref: String) { stubbedCommitShas[ref] = sha }
    func fail(commitSha on: Bool) { failsCommitSha = on }
    func set(stashes list: [StashEntry]) { stubbedStashes = list }
    func fail(stashes on: Bool) { failsStashes = on }
    func set(unpushed shas: Set<String>) { stubbedUnpushed = shas }
    func fail(unpushed on: Bool) { failsUnpushed = on }

    func commitSha(of ref: String) async throws -> String? {
        commitShaCalls.append(ref)
        if failsCommitSha { throw ProcessError.failed(command: "git rev-parse", status: 128, stderr: "gone") }
        if let sha = stubbedCommitShas[ref] { return sha }
        guard ref.hasPrefix("refs/heads/") else { return nil }
        return stubbedLocalBranches.first { "refs/heads/\($0.name)" == ref }?.tipSha
    }

    func stashes() async throws -> [StashEntry] {
        stashesCalls += 1
        // The whole result is taken before suspending, the way `status()` does: a held read
        // answers for the repository as it was when asked, list or failure.
        let snapshot = stubbedStashes
        let fails = failsStashes
        if isHeld(.stashes) { await park(.stashes) }
        if fails { throw ProcessError.failed(command: "git stash list", status: 128, stderr: "gone") }
        return snapshot
    }

    // MARK: Stash actions

    /// Makes `stash`, `pop` and `drop` throw `error` after recording the call; nil lets them succeed.
    func fail(stashActionsWith error: (any Error)?) { stashActionError = error }
    /// What `status()` reports once a pop returns, whatever its outcome: a pop that stops on
    /// conflicts or before its drop has still changed the working tree.
    func set(filesAfterPop list: [ChangedFile]?) { filesAfterPop = list }

    /// Like git: a new top entry when `files` hold a change the options include, removing
    /// those rows; otherwise nothing, as for "No local changes to save".
    func stash(message: String?, includeUntracked: Bool) async throws {
        stashPushCalls.append(StashPushCall(message: message, includeUntracked: includeUntracked))
        if isHeld(.stashActions) { await park(.stashActions) }
        if let stashActionError { throw stashActionError }
        // A paired move is a tracked deletion plus an untracked destination.
        let hasTracked = files.contains { $0.kind != .untracked }
        let hasUntracked = files.contains { $0.kind == .untracked || $0.isUntrackedMove }
        guard hasTracked || (includeUntracked && hasUntracked) else { return }
        // Without `-u`, git stashes a paired move's deletion and leaves its destination.
        let leftBehind =
            includeUntracked ? [] : files.filter(\.isUntrackedMove).map { changedFile($0.path, kind: .untracked) }
        files.removeAll { $0.kind != .untracked || includeUntracked }
        files += leftBehind
        let savesUntracked = includeUntracked && hasUntracked
        let pushed = StashEntry(
            stashIndex: 0, sha: objectID("pushed\(stashPushCalls.count)"), shortSha: "p\(stashPushCalls.count)",
            parents: [objectID("base"), objectID("index")] + (savesUntracked ? [objectID("untracked")] : []),
            committedAt: Date(timeIntervalSince1970: 1_789_300_000), author: "Tester",
            message: message ?? "WIP on main", sourceBranch: "main", hasDefaultMessage: message == nil,
            churn: nil)
        stubbedStashes = [pushed] + stubbedStashes.map { $0.reindexed(to: $0.stashIndex + 1) }
    }

    func pop(_ entry: StashEntry) async throws {
        popCalls.append(entry)
        if isHeld(.stashActions) { await park(.stashActions) }
        if let filesAfterPop { files = filesAfterPop }
        try finishStashAction(on: entry)
    }

    func drop(_ entry: StashEntry) async throws {
        dropCalls.append(entry)
        if isHeld(.stashActions) { await park(.stashActions) }
        try finishStashAction(on: entry)
    }

    /// Throws the configured error, or removes the entry as git would.
    private func finishStashAction(on entry: StashEntry) throws {
        if let stashActionError { throw stashActionError }
        stubbedStashes.removeAll { $0.stashIndex == entry.stashIndex && $0.sha == entry.sha }
    }

    func unpushedCommits(tip: String, upstreamTip: String) async throws -> Set<String> {
        unpushedCalls.append((tip: tip, upstreamTip: upstreamTip))
        if failsUnpushed { throw ProcessError.failed(command: "git rev-list", status: 128, stderr: "gone") }
        return stubbedUnpushed
    }

    func changedFiles(in commit: CommitRef) async throws -> [ChangedFile] {
        commitFileCalls += 1
        if isHeld(.commitFiles) { await park(.commitFiles) }
        if failsCommitFiles {
            throw ProcessError.failed(command: "git diff-tree", status: 128, stderr: "bad object")
        }
        // Like `GitClient`, a stash's untracked files come from its third parent's own list.
        let untracked = commit.untrackedCommit.flatMap { commitFiles[$0.sha] } ?? []
        return (commitFiles[commit.sha] ?? []) + untracked
    }

    func changedFiles(in range: CommitRange) async throws -> [ChangedFile] {
        if isHeld(.rangeFiles) { await park(.rangeFiles) }
        if failsRangeFiles { throw ProcessError.failed(command: "git diff-tree", status: 128, stderr: "bad object") }
        return rangeFiles
    }

    func contents(of path: String, at revision: String) async throws -> Data {
        beginRead(path)
        defer { endRead() }
        if isHeld(.revisionReads) { await park(.revisionReads) }
        contentRevisions.append((path, revision))
        return Data("\(revision):\(path)".utf8)
    }

    func indexContents(of path: String) async throws -> Data? {
        beginRead(path)
        defer { endRead() }
        return index[path] ?? Data("old \(path)".utf8)
    }

    func headContents(of path: String) async throws -> Data? {
        beginRead(path)
        defer { endRead() }
        return Data("head \(path)".utf8)
    }

    func worktreeContents(of path: String) async throws -> Data? {
        beginRead(path)
        defer { endRead() }
        if isHeld(.reads) { await park(.reads) }
        if heldPaths.contains(path) {
            await withCheckedContinuation { pathWaiters[path, default: []].append($0) }
        }
        if failingWorktreePaths.contains(path) {
            throw ProcessError.failed(command: "read \(path)", status: 1, stderr: "permission denied")
        }
        if let override = worktree[path] { return override }
        return Data("new \(path)".utf8)
    }

    func blobContents(_ oid: String) async throws -> Data? {
        blobReads.append(oid)
        return blobs[oid]
    }

    func worktreeState(of path: String) async -> DiffInputFingerprint.Worktree {
        worktreeStates[path] ?? .unknown
    }

    func perform(_ action: GitFileAction, on paths: [String]) async throws {
        performed.append((action, paths))
        if isHeld(.actions) { await park(.actions) }
        if failsActions { throw ProcessError.failed(command: "git add", status: 128, stderr: "index.lock exists") }
        if let filesAfterWrite { files = filesAfterWrite }
    }

    func trash(_ paths: [String]) async throws {
        trashed.append(paths)
        if isHeld(.actions) { await park(.actions) }
        if failsActions {
            throw ProcessError.failed(command: "trash", status: 1, stderr: "could not move to Trash")
        }
        if let filesAfterWrite { files = filesAfterWrite }
    }

    // MARK: Commits

    func set(commitDefaults defaults: CommitDefaults) { stubbedDefaults = defaults }
    func fail(commitDefaults on: Bool) { failsCommitDefaults = on }
    /// Makes `commit` throw, after recording the message.
    func fail(commit on: Bool) { failsCommit = on }

    func commitDefaults() async throws -> CommitDefaults {
        commitDefaultsCalls += 1
        // Snapshot before suspending, the way `status()` does: a held read reports what
        // the repository looked like when it was asked.
        let snapshot = stubbedDefaults
        if isHeld(.commitDefaults) { await park(.commitDefaults) }
        if failsCommitDefaults {
            throw ProcessError.failed(command: "git rev-parse", status: 128, stderr: "gone")
        }
        return snapshot
    }

    /// The patch for every context size without one of its own.
    func set(stagedPatch text: String) { stubbedStagedPatch = text }
    func set(stagedPatch text: String, forContextLines contextLines: Int) {
        stubbedStagedPatches[contextLines] = text
    }

    func stagedPatch(contextLines: Int) async throws -> String {
        stagedPatchContextLines.append(contextLines)
        if isHeld(.stagedPatch) { await park(.stagedPatch) }
        return stubbedStagedPatches[contextLines] ?? stubbedStagedPatch
    }

    /// Held and released with the other writes, so a commit can be queued behind a stage.
    func commit(message: String) async throws {
        commitMessages.append(message)
        if isHeld(.actions) { await park(.actions) }
        if failsCommit {
            throw ProcessError.failed(command: "git commit", status: 1, stderr: "pre-commit hook failed")
        }
        if let filesAfterWrite { files = filesAfterWrite }
    }
}

/// What a failing stub generation throws.
struct StubGenerationError: LocalizedError {
    var errorDescription: String? { "the model gave up" }
}

/// A stream the test drives by hand: the stub hands over its continuation and request,
/// and the test yields, finishes or fails it whenever it likes. A lock rather than an
/// actor so a test can drive it without awaiting.
final class StubGenerationChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?
    private var calls = 0
    private var request: CommitMessagePrompt.Request?

    /// How many generations the stub started through this channel.
    var generateCalls: Int { lock.withLock { calls } }
    /// What the latest generation was asked to describe.
    var lastRequest: CommitMessagePrompt.Request? { lock.withLock { request } }

    func register(
        _ continuation: AsyncThrowingStream<String, any Error>.Continuation, request: CommitMessagePrompt.Request
    ) {
        lock.withLock {
            self.continuation = continuation
            self.request = request
            calls += 1
        }
    }

    func yield(_ text: String) { lock.withLock { continuation }?.yield(text) }
    func finish() { lock.withLock { continuation }?.finish() }
    func fail() { lock.withLock { continuation }?.finish(throwing: StubGenerationError()) }
}

/// A generator under the test's control: it yields `texts` in order, then throws
/// `failure` if there is one. `unavailableReason` stands in for a model that cannot run.
/// With a `channel`, it yields nothing of its own and leaves the stream open for the test.
struct StubCommitMessageGenerator: CommitMessageGenerator {
    var texts: [String] = []
    var failure: StubGenerationError?
    var unavailableReason: String?
    var channel: StubGenerationChannel?
    var characterBudget = 100_000

    func generate(_ request: CommitMessagePrompt.Request) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            if let channel {
                channel.register(continuation, request: request)
                return
            }
            for text in texts { continuation.yield(text) }
            continuation.finish(throwing: failure)
        }
    }
}

@MainActor
final class NoopWatcher: RepoWatching {
    private(set) var stopped = false
    /// Every dependency set handed over, in order.
    private(set) var dependencies: [Set<String>] = []
    func setDependencies(_ paths: Set<String>) { dependencies.append(paths) }
    func stop() { stopped = true }
}

/// One `stash` push the stub was asked for.
struct StashPushCall: Equatable, Sendable {
    let message: String?
    let includeUntracked: Bool
}

extension StashEntry {
    /// The same entry at another position, as a push shifts every older one down.
    fileprivate func reindexed(to index: Int) -> StashEntry {
        StashEntry(
            stashIndex: index, sha: sha, shortSha: shortSha, parents: parents, committedAt: committedAt,
            author: author, message: message, sourceBranch: sourceBranch, hasDefaultMessage: hasDefaultMessage,
            churn: churn)
    }
}
