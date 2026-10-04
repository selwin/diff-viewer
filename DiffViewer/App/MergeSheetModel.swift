import Foundation
import Observation

/// What the Merge sheet shows about one merge: the commits it brings in and the predicted
/// outcome, which share the picker's preview cache. Loading starts with `start()` and
/// stops with `stop()`, so a sheet that is closed asks for nothing more.
@MainActor
@Observable
final class MergeSheetModel {
    /// One more than shown, so a longer list is noticed without counting it.
    static let commitRequestLimit = 21
    static let shownCommitLimit = 20
    /// Longer lists would make the warning taller than the sheet's other content.
    static let conflictPathLimit = 5

    /// Where the conflict prediction stands.
    enum PreviewStatus: Equatable {
        case loading
        case ready(MergePreview)
        /// The prediction failed or there is nothing to ask; the merge is still allowed.
        case unavailable
    }

    let target: MergeTarget
    private(set) var previewStatus: PreviewStatus = .loading
    /// Nil until read, or if git could not list them.
    private(set) var commits: [CommitSummary]?
    private(set) var isLoadingCommits = true

    @ObservationIgnored private let previews: MergePreviewLoader?
    @ObservationIgnored private let loadCommits: (Int) async -> [CommitSummary]?
    @ObservationIgnored private var token: MergePreviewLoader.ConsumerToken?
    @ObservationIgnored private(set) var commitsTask: Task<Void, Never>?

    /// `loadCommits` is asked for at most `commitRequestLimit` commits.
    init(target: MergeTarget, previews: MergePreviewLoader?, loadCommits: @escaping (Int) async -> [CommitSummary]?) {
        self.target = target
        self.previews = previews
        self.loadCommits = loadCommits
    }

    func start() {
        if token == nil { startPreview() }
        // Nothing to list, so don't spend a git call on it.
        if isAlreadyMerged {
            commits = []
            isLoadingCommits = false
        } else {
            loadCommitsIfNeeded()
        }
    }

    /// Answers from the cache when it can; otherwise `loading` until the loader reports
    /// the key, which it does for a failed call too.
    private func startPreview() {
        guard let previews else {
            previewStatus = .unavailable
            return
        }
        let key = target.previewKey
        let token = previews.registerConsumer { [weak self] _ in
            guard let self else { return }
            previewStatus = self.previews?.cachedPreview(for: key).map { .ready($0) } ?? .unavailable
        }
        self.token = token
        if let cached = previews.cachedPreview(for: key) {
            previewStatus = .ready(cached)
        } else {
            previewStatus = .loading
            previews.setRequestedKeys([key], for: token)
        }
    }

    /// Stops results reaching the model and releases the loader's request. A git process
    /// already running is not terminated: `ProcessRunner` does not kill it on cancellation.
    func stop() {
        if let token { previews?.unregisterConsumer(token) }
        token = nil
        commitsTask?.cancel()
        commitsTask = nil
    }

    private func loadCommitsIfNeeded() {
        guard commitsTask == nil, commits == nil else { return }
        commitsTask = Task { [weak self, loadCommits] in
            let loaded = await loadCommits(Self.commitRequestLimit)
            guard !Task.isCancelled, let self else { return }
            commits = loaded
            isLoadingCommits = false
        }
    }

    // MARK: What the sheet says

    var isAlreadyMerged: Bool { previewStatus == .ready(.alreadyMerged) }

    /// Merging waits for the prediction, so the warning is seen before the button works.
    var canMerge: Bool { previewStatus != .loading && !isAlreadyMerged }

    private var preview: MergePreview? {
        if case let .ready(preview) = previewStatus { preview } else { nil }
    }

    var shownCommits: [CommitSummary] { Array((commits ?? []).prefix(Self.shownCommitLimit)) }

    /// "and N more" when the preview knows the total, else "and more" once the list was
    /// cut off; nil when every commit is shown.
    var moreCommitsText: String? {
        Self.moreCommitsText(listed: commits?.count ?? 0, total: preview?.commitCount)
    }

    static func moreCommitsText(listed: Int, total: Int?) -> String? {
        let shown = min(listed, shownCommitLimit)
        if let total, total > shown { return "and \(total - shown) more" }
        return listed > shownCommitLimit ? "and more" : nil
    }

    /// Nil unless conflicts are predicted.
    var conflictText: String? {
        guard case let .conflicts(_, paths)? = preview else { return nil }
        return Self.conflictText(paths: paths)
    }

    static func conflictText(paths: [String]) -> String {
        guard !paths.isEmpty else { return "Merging will conflict." }
        let noun = paths.count == 1 ? "1 file" : "\(paths.count) files"
        let listed = paths.prefix(conflictPathLimit).joined(separator: ", ")
        let rest = paths.count - conflictPathLimit
        return "Merging will conflict in \(noun): \(listed)" + (rest > 0 ? " and \(rest) more" : "")
    }
}
