import Foundation

/// Loads the two versions of a changed file from git and builds its diff.
enum DiffEngine {
    struct Sources: Sendable {
        let old: Data
        let new: Data
        let fileName: String
    }

    static func sources(for file: ChangedFile, client: any RepoClient) async throws -> Sources {
        let old: Data?
        let new: Data?
        switch file.area {
        case .unstaged:
            switch file.kind {
            case .untracked:
                old = nil
                new = try await client.worktreeContents(of: file.path)
            case .unmerged:
                old = try await client.headContents(of: file.path)
                new = try await client.worktreeContents(of: file.path)
            default:
                old = try await client.indexContents(of: file.path)
                new = file.kind == .deleted ? nil : try await client.worktreeContents(of: file.path)
            }
        case .staged:
            old = file.kind == .added ? nil : try await client.headContents(of: file.originalPath ?? file.path)
            new = file.kind == .deleted ? nil : try await client.indexContents(of: file.path)
        case let .commit(ref):
            // Which sides exist is decided here, from the change kind and whether the
            // commit has a parent — never inferred from a read that came back empty.
            if file.kind == .added {
                old = nil
            } else if let parent = ref.firstParentSHA {
                old = try await client.contents(of: file.originalPath ?? file.path, at: parent)
            } else {
                old = nil  // A root commit: nothing precedes it.
            }
            new = file.kind == .deleted ? nil : try await client.contents(of: file.path, at: ref.sha)
        }
        return Sources(old: old ?? Data(), new: new ?? Data(), fileName: file.fileName)
    }

    /// Whether a pair is text with differences, i.e. something difft can work on.
    /// Compares whole buffers; call it off the main actor for large files.
    static func needsDifft(_ sources: Sources) -> Bool {
        !isBinary(sources.old) && !isBinary(sources.new) && sources.old != sources.new
    }

    /// Builds the document, taking difft hints from `cache` (which runs difft on a
    /// miss). Without hints the view still works as a plain line diff.
    static func build(_ sources: Sources, hideWhitespace: Bool, cache: DifftCache, priority: DifftCache.Priority) async
        -> DiffContent
    {
        if isBinary(sources.old) || isBinary(sources.new) { return .binary }
        if sources.old == sources.new { return .identical }

        let oldText = String(decoding: sources.old, as: UTF8.self)
        let newText = String(decoding: sources.new, as: UTF8.self)

        let difft = await cache.result(
            old: sources.old, new: sources.new, fileName: sources.fileName, priority: priority)
        let hints = difft?.hints ?? DifftHints()
        let language = difft?.language

        let document = await Task.detached(priority: .userInitiated) {
            let oldLines = TextLines.split(oldText)
            let newLines = TextLines.split(newText)
            let rows = DiffAligner.align(
                oldLines: oldLines, newLines: newLines, hideWhitespace: hideWhitespace, hints: hints)
            return DiffDocument(oldLines: oldLines, newLines: newLines, rows: rows, language: language)
        }.value
        return .text(document)
    }

    static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }
}
