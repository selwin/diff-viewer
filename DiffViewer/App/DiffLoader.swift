import Foundation
import Observation

/// Computes the diff for the selection, cancelling stale work when the selection or the
/// whitespace mode changes.
///
/// Two modes, one set of published properties. A single file keeps the previous content
/// on screen while it reloads, so re-diffing the same file does not blank the panes. A
/// changeset is about the whole list rather than one file, so it starts from an empty
/// view and grows as the assembler completes sections.
@MainActor
@Observable
final class DiffLoader {
    private(set) var content: DiffContent?
    private(set) var contentFileID: ChangedFile.ID?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Syntax styles for `content`, arriving shortly after the diff itself.
    private(set) var styles: DocumentStyles?
    /// True while styles for the published content are being computed. Always false for a
    /// changeset, whose highlighting runs inside the assembler and so is covered by
    /// `isLoading`.
    private(set) var isHighlighting = false
    /// How much of an All-changes load has been published, while one is running.
    private(set) var changesetProgress: (completed: Int, total: Int)?

    /// True while a diff or its highlighting is in flight.
    var hasActiveWork: Bool { isLoading || isHighlighting }

    private let cache: DifftCache
    private var task: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    private var generation = 0

    init(cache: DifftCache) {
        self.cache = cache
    }

    /// Stops any in-flight diff and highlight. Published content and styles stay as
    /// they are; the cancelled generation can no longer publish or start highlighting.
    /// Returns whether anything was actually in flight.
    @discardableResult
    func cancelActiveWork() -> Bool {
        let wasActive = hasActiveWork
        task?.cancel()
        highlightTask?.cancel()
        generation += 1
        isLoading = false
        isHighlighting = false
        return wasActive
    }

    func load(file: ChangedFile?, client: (any RepoClient)?, hideWhitespace: Bool) {
        cancelActiveWork()
        let gen = generation
        changesetProgress = nil
        // A changeset on screen belongs to another selection entirely.
        if case .changeset = content {
            content = nil
            styles = nil
            contentFileID = nil
        }
        guard let file, let client else {
            content = nil
            contentFileID = nil
            isLoading = false
            errorMessage = nil
            return
        }
        if contentFileID != file.id {
            content = nil
            styles = nil
            contentFileID = file.id
        }
        isLoading = true
        errorMessage = nil
        task = Task {
            do {
                let sources = try await DiffEngine.sources(for: file, client: client)
                try Task.checkCancellation()
                let result = await DiffEngine.build(
                    sources, hideWhitespace: hideWhitespace, cache: cache, priority: .foreground)
                try Task.checkCancellation()
                guard gen == generation else { return }
                content = result
                contentFileID = file.id
                isLoading = false
                if case let .text(document) = result {
                    highlight(document, fileName: file.fileName, generation: gen)
                }
            } catch is CancellationError {
                // A newer request superseded this one.
            } catch {
                guard gen == generation else { return }
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    /// Loads every file as one changeset, publishing it as sections complete.
    func load(
        changeset files: [ChangedFile], client: (any RepoClient)?, hideWhitespace: Bool,
        foldOptions: FoldOptions = FoldOptions()
    ) {
        cancelActiveWork()
        let gen = generation
        content = nil
        contentFileID = nil
        styles = nil
        errorMessage = nil
        changesetProgress = nil
        guard let client else { return }
        isLoading = true
        let assembler = ChangesetAssembler(
            files: files, client: client, hideWhitespace: hideWhitespace, foldOptions: foldOptions, cache: cache)
        task = Task { [weak self] in
            guard let self else { return }
            await assembler.run { [self] publication in
                await publish(publication, generation: gen)
            }
            guard gen == generation else { return }
            isLoading = false
            changesetProgress = nil
        }
    }

    private func publish(_ publication: ChangesetAssembler.Publication, generation gen: Int) {
        guard gen == generation else { return }
        switch publication {
        case let .document(document, snapshot, completed, total):
            content = .changeset(document)
            styles = snapshot
            changesetProgress = (completed, total)
        case let .styles(snapshot):
            styles = snapshot
        }
    }

    private func highlight(_ document: DiffDocument, fileName: String, generation gen: Int) {
        let oldLines = document.oldLines
        let newLines = document.newLines
        let documentID = document.id
        isHighlighting = true
        highlightTask = Task {
            // Both sides are independent parses; run them in parallel.
            async let old = Task.detached(priority: .userInitiated) {
                Highlighter.highlight(lines: oldLines, fileName: fileName)
            }.value
            async let new = Task.detached(priority: .userInitiated) {
                Highlighter.highlight(lines: newLines, fileName: fileName)
            }.value
            let result = await DocumentStyles(documentID: documentID, revision: 0, old: old, new: new)
            guard !Task.isCancelled, gen == generation else { return }
            styles = result
            isHighlighting = false
        }
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
}
