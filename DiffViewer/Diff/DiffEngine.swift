import Foundation

/// Loads the two versions of a changed file from git and builds its diff.
enum DiffEngine {
    struct Sources: Sendable {
        let old: Data
        let new: Data
        let fileName: String
        /// Distinguishes absent versions from existing zero-byte files.
        let oldExists: Bool
        let newExists: Bool

        init(old: Data, new: Data, fileName: String, oldExists: Bool = true, newExists: Bool = true) {
            self.old = old
            self.new = new
            self.fileName = fileName
            self.oldExists = oldExists
            self.newExists = newExists
        }
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
                // An unstaged rename's index entry is still at the old path.
                old = try await client.indexContents(of: file.originalPath ?? file.path)
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
        return Sources(
            old: old ?? Data(), new: new ?? Data(), fileName: file.fileName,
            oldExists: old != nil, newExists: new != nil)
    }

    /// Whether a pair is text with differences, i.e. something difft can work on.
    /// Compares whole buffers; call it off the main actor for large files.
    static func needsDifft(_ sources: Sources) -> Bool {
        !isBinary(sources.old) && !isBinary(sources.new) && sources.old != sources.new
    }

    typealias Highlight = @Sendable ([String], String) async -> [[StyleRun]]?

    static let defaultHighlight: Highlight = { lines, fileName in
        await Task.detached(priority: .userInitiated) {
            Highlighter.highlight(lines: lines, fileName: fileName)
        }.value
    }

    /// A finished diff and the styles for it. Styles are nil for binary or identical
    /// content, which has no document to colour.
    struct Output: Sendable {
        let content: DiffContent
        let styles: SyntaxStyles?
    }

    /// Builds and highlights the document, or returns it from `resultCache`. On a miss,
    /// difft hints come from `cache` (which runs difft as needed); without hints the view
    /// still works as a plain line diff. Throws only `CancellationError`.
    static func build(
        _ sources: Sources, hideWhitespace: Bool, cache: DifftCache, resultCache: DiffResultCache,
        priority: DifftCache.Priority, highlight: Highlight = defaultHighlight
    ) async throws -> Output {
        try Task.checkCancellation()
        if isBinary(sources.old) || isBinary(sources.new) { return Output(content: .binary, styles: nil) }
        if sources.old == sources.new { return Output(content: .identical, styles: nil) }

        let difftKey = DifftCache.key(old: sources.old, new: sources.new, fileName: sources.fileName)
        let key = DiffResultCache.Key(difftKey: difftKey, hideWhitespace: hideWhitespace)
        if let entry = await resultCache.entry(for: key) {
            return Output(content: .text(entry.document), styles: entry.styles)
        }

        let oldText = String(decoding: sources.old, as: UTF8.self)
        let newText = String(decoding: sources.new, as: UTF8.self)

        let difft = await cache.result(
            for: difftKey, old: sources.old, new: sources.new, fileName: sources.fileName, priority: priority)
        try Task.checkCancellation()
        let hints = difft?.hints ?? DifftHints()
        let language = difft?.language

        let document = await Task.detached(priority: .userInitiated) {
            let oldLines = TextLines.split(oldText)
            let newLines = TextLines.split(newText)
            let rows = DiffAligner.align(
                oldLines: oldLines, newLines: newLines, hideWhitespace: hideWhitespace, hints: hints)
            return DiffDocument(oldLines: oldLines, newLines: newLines, rows: rows, language: language)
        }.value
        try Task.checkCancellation()

        // Sequential, so a caller processing one file at a time runs one parse at a time.
        let old = await highlight(document.oldLines, sources.fileName)
        try Task.checkCancellation()
        let new = await highlight(document.newLines, sources.fileName)
        let styles = SyntaxStyles(old: old, new: new)

        // Only a successful difft result is kept: `DifftCache` forgets a failure after a
        // while so the fallback document is retried, and this store has no expiry. A
        // result finished after cancellation is still kept: it is valid and the next
        // load hits; the caller decides whether to publish it.
        if difft != nil {
            await resultCache.store(DiffResultCache.Entry(document: document, styles: styles), for: key)
        }
        return Output(content: .text(document), styles: styles)
    }

    static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }
}
