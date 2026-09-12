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

    private var task: Task<Void, Never>?
    private var generation = 0

    func load(file: ChangedFile?, client: GitClient?, hideWhitespace: Bool) {
        task?.cancel()
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
            contentFileID = file.id
        }
        isLoading = true
        errorMessage = nil
        task = Task {
            do {
                let sources = try await DiffEngine.sources(for: file, client: client)
                try Task.checkCancellation()
                let result = await DiffEngine.build(sources, hideWhitespace: hideWhitespace)
                try Task.checkCancellation()
                guard gen == generation else { return }
                content = result
                contentFileID = file.id
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
}
