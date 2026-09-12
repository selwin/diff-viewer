import Foundation
import Observation

/// Computes the diff for the selected file, cancelling stale work when the selection
/// or whitespace mode changes. Keeps the previous content visible while reloading.
@MainActor
@Observable
final class DiffLoader {
    private(set) var content: DiffContent?
    private(set) var contentFileID: ChangedFile.ID?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Syntax styles for `content`, arriving shortly after the diff itself.
    private(set) var styles: DocumentStyles?

    private let cache: DifftCache
    private var task: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    private var generation = 0

    init(cache: DifftCache) {
        self.cache = cache
    }

    func load(file: ChangedFile?, client: GitClient?, hideWhitespace: Bool) {
        task?.cancel()
        highlightTask?.cancel()
        generation += 1
        let gen = generation
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
                let result = await DiffEngine.build(sources, hideWhitespace: hideWhitespace, cache: cache, priority: .foreground)
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

    private func highlight(_ document: DiffDocument, fileName: String, generation gen: Int) {
        let oldLines = document.oldLines
        let newLines = document.newLines
        let documentID = document.id
        highlightTask = Task {
            // Both sides are independent parses; run them in parallel.
            async let old = Task.detached(priority: .userInitiated) {
                Highlighter.highlight(lines: oldLines, fileName: fileName)
            }.value
            async let new = Task.detached(priority: .userInitiated) {
                Highlighter.highlight(lines: newLines, fileName: fileName)
            }.value
            let result = await DocumentStyles(documentID: documentID, old: old, new: new)
            guard !Task.isCancelled, gen == generation else { return }
            styles = result
        }
    }
}

struct DocumentStyles: Sendable {
    let documentID: UUID
    let old: [[StyleRun]]?
    let new: [[StyleRun]]?
}
