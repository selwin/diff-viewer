import Foundation
import Observation

/// How the merge illustration marks the commits coming in: one dot each up to five, a
/// capsule beyond that, nothing while the count is unknown or zero.
enum CommitMarks: Equatable {
    case none
    case dots(Int)
    case capsule

    static func forCount(_ count: Int) -> CommitMarks {
        switch count {
        case ..<1: .none
        case 1...5: .dots(count)
        default: .capsule
        }
    }
}

/// What the Merge sheet shows about one merge: the predicted outcome, which shares the
/// picker's preview cache, and how much the source changes. Loading starts with `start()`
/// and stops with `stop()`, so a sheet that is closed asks for nothing more.
@MainActor
@Observable
final class MergeSheetModel {
    /// Where the conflict prediction stands.
    enum PreviewStatus: Equatable {
        case loading
        case ready(MergePreview)
        /// The prediction failed or there is nothing to ask; the merge is still allowed.
        case unavailable
    }

    /// Where the file and line counts stand.
    enum IncomingChangesStatus: Equatable {
        case loading
        case ready(IncomingChangeSummary)
        /// Git could not count them; the merge is still allowed.
        case unavailable
    }

    /// The headline result, which the view maps to an icon and colour.
    enum Outcome: Equatable {
        case checking
        case clean
        case conflicts
        case alreadyMerged
        case unknown
    }

    /// The status box's second line.
    enum Statistics: Equatable {
        case hidden
        /// Still counting; the view reserves the line.
        case pending
        case ready(files: String, added: String, deleted: String)
    }

    let target: MergeTarget
    private(set) var previewStatus: PreviewStatus = .loading
    private(set) var incomingChangesStatus: IncomingChangesStatus = .loading

    @ObservationIgnored private let previews: MergePreviewLoader?
    @ObservationIgnored private let loadIncomingChanges: () async -> IncomingChangeSummary?
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private var token: MergePreviewLoader.ConsumerToken?
    /// Exposed so tests can await it.
    @ObservationIgnored private(set) var summaryTask: Task<Void, Never>?
    /// Tells a restarted request from the one `stop()` cancelled, whose late answer is dropped.
    @ObservationIgnored private var summaryTaskID = 0

    /// `loadIncomingChanges` returns nil when git could not count.
    init(
        target: MergeTarget, previews: MergePreviewLoader?, locale: Locale = .current,
        loadIncomingChanges: @escaping () async -> IncomingChangeSummary?
    ) {
        self.target = target
        self.previews = previews
        self.locale = locale
        self.loadIncomingChanges = loadIncomingChanges
    }

    func start() {
        // A finished preview is never asked for again; an unfinished one joins the loader's running call.
        if token == nil, previewStatus == .loading { startPreview() }
        // Summary state is ignored when the preview is already merged; no summary request is started.
        if !isAlreadyMerged, incomingChangesStatus == .loading, summaryTask == nil { startSummary() }
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

    private func startSummary() {
        summaryTaskID += 1
        let id = summaryTaskID
        summaryTask = Task { [weak self, loadIncomingChanges] in
            let summary = await loadIncomingChanges()
            guard !Task.isCancelled, let self, summaryTaskID == id else { return }
            incomingChangesStatus = summary.map { .ready($0) } ?? .unavailable
            summaryTask = nil
        }
    }

    /// Stops results reaching the model and releases the loader's request. A git process
    /// already running is not terminated: `ProcessRunner` does not kill it on cancellation.
    func stop() {
        if let token { previews?.unregisterConsumer(token) }
        token = nil
        summaryTask?.cancel()
        summaryTask = nil
    }

    // MARK: What the sheet says

    var isAlreadyMerged: Bool { previewStatus == .ready(.alreadyMerged) }

    /// Merging waits for the prediction, so the warning is seen before the button works.
    var canMerge: Bool { previewStatus != .loading && !isAlreadyMerged }

    private var preview: MergePreview? {
        if case let .ready(preview) = previewStatus { preview } else { nil }
    }

    /// Nil while the preview is loading or unavailable.
    var commitCount: Int? { preview?.commitCount }

    var commitMarks: CommitMarks { CommitMarks.forCount(commitCount ?? 0) }

    /// Nil when the count is unknown or zero.
    var commitsText: String? {
        guard let commitCount, commitCount > 0 else { return nil }
        return Self.commitsText(commitCount, locale: locale)
    }

    var outcome: Outcome {
        switch previewStatus {
        case .loading: .checking
        case .unavailable: .unknown
        case let .ready(preview):
            switch preview {
            case .alreadyMerged: .alreadyMerged
            case .clean: .clean
            case .conflicts: .conflicts
            }
        }
    }

    var statusTitle: String {
        switch outcome {
        case .checking: "Checking…"
        case .clean: "No Conflicts"
        case .conflicts: Self.conflictTitle(fileCount: conflicts.count, locale: locale)
        case .alreadyMerged: "Already Merged"
        case .unknown: "Couldn't Predict Conflicts"
        }
    }

    var statistics: Statistics {
        guard !isAlreadyMerged else { return .hidden }
        switch incomingChangesStatus {
        case .loading: return .pending
        case .unavailable: return .hidden
        case let .ready(summary):
            return .ready(
                files: Self.filesText(summary.fileCount, locale: locale),
                added: Self.addedText(summary.addedLineCount, locale: locale),
                deleted: Self.deletedText(summary.deletedLineCount, locale: locale))
        }
    }

    /// Empty unless conflicts are predicted.
    var conflicts: [MergeConflict] {
        if case let .conflicts(_, files)? = preview { files } else { [] }
    }

    /// Nil unless conflicts are predicted, even when git named no file.
    var conflictNote: String? {
        outcome == .conflicts ? Self.conflictNote(fileCount: conflicts.count, locale: locale) : nil
    }

    var primaryTitle: String { outcome == .conflicts ? "Merge Anyway" : "Merge" }

    var accessibilityLabel: String {
        guard let commitsText else { return "Merge \(target.sourceName) into \(target.destinationBranch)" }
        return "\(target.sourceName), with \(commitsText), merges into \(target.destinationBranch)"
    }

    // MARK: Wording

    static func commitsText(_ count: Int, locale: Locale) -> String {
        count == 1 ? "1 commit" : "\(count.formatted(.number.locale(locale))) commits"
    }

    static func filesText(_ count: Int, locale: Locale) -> String {
        count == 1 ? "1 file" : "\(count.formatted(.number.locale(locale))) files"
    }

    static func conflictTitle(fileCount: Int, locale: Locale) -> String {
        switch fileCount {
        case 0: "Conflicts Predicted"
        case 1: "1 File with Conflicts"
        default: "\(fileCount.formatted(.number.locale(locale))) Files with Conflicts"
        }
    }

    static func conflictNote(fileCount: Int, locale: Locale) -> String {
        let place = fileCount == 0 ? "" : " in \(filesText(fileCount, locale: locale))"
        return
            "Conflicts are predicted\(place). If the merge stops, resolve them in your editor, then stage and commit here."
    }

    static func addedText(_ count: Int, locale: Locale) -> String {
        "+" + count.formatted(.number.locale(locale))
    }

    /// With a true minus sign (U+2212), which lines up with the plus.
    static func deletedText(_ count: Int, locale: Locale) -> String {
        "\u{2212}" + count.formatted(.number.locale(locale))
    }
}
