import Foundation
import Observation

/// Computes the diff for the selection, cancelling stale work when the selection or the
/// whitespace mode changes.
///
/// Two modes, one set of published properties. A single file keeps the previous content
/// on screen while it reloads, so re-diffing the same file does not blank the panes. A
/// changeset starts from an empty view for a new selection and grows as the assembler
/// completes sections; when the same view reloads, the previous document stays on screen
/// until the whole replacement is ready.
@MainActor
@Observable
final class DiffLoader {
    private(set) var content: DiffContent? {
        didSet { onPresentationChange?() }
    }
    private(set) var contentFileID: ChangedFile.ID?
    private(set) var isLoading = false
    /// The detail view hides the panes while an error is set, even with content still
    /// loaded, so both count as a change to what is presented.
    private(set) var errorMessage: String? {
        didSet { onPresentationChange?() }
    }
    /// Syntax styles for `content`, published in the same turn as the content itself.
    private(set) var styles: DocumentStyles?
    /// Rendered preview for the current single file. Published with content and retained
    /// during same-file reloads.
    private(set) var imagePreview: ImagePreview?
    /// How much of an All-changes load has been published, while one is running.
    private(set) var changesetProgress: (completed: Int, total: Int)?

    /// Called after every write to `content` or `errorMessage`, so find can drop its state
    /// the moment the panes stop showing searchable text.
    @ObservationIgnored var onPresentationChange: (@MainActor () -> Void)?

    /// True while a diff (including its highlighting) is in flight.
    var hasActiveWork: Bool { isLoading }

    private let cache: DifftCache
    private let resultCache: DiffResultCache
    /// One cache per window, so a save re-highlights only the side that changed.
    private let highlight: DiffEngine.Highlight
    private var task: Task<Void, Never>?
    private var generation = 0

    init(
        cache: DifftCache, resultCache: DiffResultCache = DiffResultCache(),
        highlightCache: HighlightCache = HighlightCache()
    ) {
        self.cache = cache
        self.resultCache = resultCache
        highlight = highlightCache.highlight()
    }

    /// Stops any in-flight diff. Published presentation state stays as it is; the cancelled
    /// generation can no longer publish. Returns whether anything was actually in flight.
    @discardableResult
    func cancelActiveWork() -> Bool {
        let wasActive = hasActiveWork
        task?.cancel()
        generation += 1
        isLoading = false
        return wasActive
    }

    func load(file: ChangedFile?, client: (any RepoClient)?, repository: RepositoryRoot?, hideWhitespace: Bool) {
        cancelActiveWork()
        let gen = generation
        changesetProgress = nil
        // A changeset on screen belongs to another selection entirely.
        if case .changeset = content {
            content = nil
            styles = nil
            imagePreview = nil
            contentFileID = nil
        }
        guard let file, let client, let repository else {
            content = nil
            imagePreview = nil
            contentFileID = nil
            isLoading = false
            errorMessage = nil
            return
        }
        if contentFileID != file.id {
            content = nil
            styles = nil
            imagePreview = nil
            contentFileID = file.id
        }
        isLoading = true
        errorMessage = nil
        task = Task {
            let signposter = PipelineMetrics.signposter
            let loadState = signposter.beginInterval("singleLoad", id: signposter.makeSignpostID())
            defer { signposter.endInterval("singleLoad", loadState) }
            do {
                let oldFormat = ImagePreview.format(for: file.originalPath ?? file.path)
                let newFormat = ImagePreview.format(for: file.path)
                // A file with a preview is always read, never reused, so its preview and its
                // diff come from the same bytes.
                let output: DiffEngine.Output
                var imageSources: DiffEngine.Sources?
                if oldFormat != nil || newFormat != nil {
                    let sources = try await DiffEngine.sources(for: file, client: client)
                    try Task.checkCancellation()
                    output = try await DiffEngine.build(
                        sources, hideWhitespace: hideWhitespace, cache: cache, resultCache: resultCache,
                        priority: .foreground, highlight: highlight)
                    imageSources = sources
                } else {
                    output = try await DiffEngine.load(
                        file, repository: repository, client: client, hideWhitespace: hideWhitespace, cache: cache,
                        resultCache: resultCache, priority: .foreground, highlight: highlight)
                }
                try Task.checkCancellation()
                // SVG stays a text diff, so it is previewed on its text content too.
                let wantsPreview =
                    switch output.content {
                    case .binary: oldFormat != nil || newFormat != nil
                    case .text: oldFormat == .svg || newFormat == .svg
                    default: false
                    }
                var preview: ImagePreview?
                if wantsPreview, let sources = imageSources {
                    // A rename may name an image on one side only; that side's decoder
                    // is the best guess for the other's bytes.
                    let oldInput = (oldFormat ?? newFormat).flatMap { format in
                        sources.oldExists ? ImagePreview.Input(data: sources.old, format: format) : nil
                    }
                    let newInput = (newFormat ?? oldFormat).flatMap { format in
                        sources.newExists ? ImagePreview.Input(data: sources.new, format: format) : nil
                    }
                    preview = try await ImagePreview.decode(old: oldInput, new: newInput)
                    try Task.checkCancellation()
                }
                guard gen == generation else { return }
                content = output.content
                contentFileID = file.id
                imagePreview = preview
                if case let .text(document) = output.content, let syntax = output.styles {
                    // A cache hit for the document already on screen keeps its snapshot,
                    // so the panes do not reshape lines they already have.
                    if styles?.documentID != document.id {
                        styles = DocumentStyles(
                            documentID: document.id, revision: 0, old: syntax.old, new: syntax.new,
                            oldOutline: syntax.oldOutline, newOutline: syntax.newOutline)
                    }
                } else {
                    styles = nil
                }
                isLoading = false
            } catch is CancellationError {
                // A newer request superseded this one.
            } catch {
                guard gen == generation else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// Loads every file as one changeset, publishing it as sections complete. With
    /// `preserveCurrentContent`, a changeset already on screen stays there and the
    /// replacement is published whole, in one step; an empty list still shows nothing.
    func load(
        changeset files: [ChangedFile], client: (any RepoClient)?, repository: RepositoryRoot?, hideWhitespace: Bool,
        foldOptions: FoldOptions = FoldOptions(), preserveCurrentContent: Bool = false
    ) {
        cancelActiveWork()
        let gen = generation
        let onScreen = if case .changeset = content { true } else { false }
        let preserved = preserveCurrentContent && client != nil && repository != nil && !files.isEmpty && onScreen
        imagePreview = nil
        if !preserved {
            content = nil
            contentFileID = nil
            styles = nil
        }
        errorMessage = nil
        changesetProgress = nil
        guard let client, let repository else { return }
        isLoading = true
        let assembler = ChangesetAssembler(
            files: files, repository: repository, client: client, hideWhitespace: hideWhitespace,
            foldOptions: foldOptions,
            publication: preserved ? .finalOnly : .progressive, cache: cache, resultCache: resultCache,
            highlight: highlight)
        task = Task { [weak self] in
            guard let self else { return }
            let signposter = PipelineMetrics.signposter
            let loadState = signposter.beginInterval("changesetLoad", id: signposter.makeSignpostID())
            await assembler.run { [self] publication in
                await publish(publication, generation: gen)
            }
            signposter.endInterval("changesetLoad", loadState)
            guard gen == generation else { return }
            isLoading = false
            changesetProgress = nil
        }
    }

    private func publish(_ publication: ChangesetAssembler.Publication, generation gen: Int) {
        guard gen == generation else { return }
        content = .changeset(publication.document)
        styles = publication.styles
        changesetProgress = (publication.completed, publication.total)
    }
}

/// Syntax styles for one document. `revision` is the changeset revision they were built
/// for, so a snapshot can be matched to the document installed in the panes; a single-file
/// document has only one revision, 0.
struct DocumentStyles: Sendable {
    /// Identifies this style snapshot independently of its document revision.
    let id = UUID()
    let documentID: UUID
    let revision: Int
    let old: [[StyleRun]]?
    let new: [[StyleRun]]?
    let oldOutline: ScopeOutline?
    let newOutline: ScopeOutline?
}
