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
        case .commit:
            // Which sides exist comes from the change kind and whether the commit has a
            // parent — never inferred from a read that came back empty.
            let sides = file.commitSides
            if let side = sides?.old {
                old = try await client.contents(of: side.path, at: side.revision)
            } else {
                old = nil
            }
            if let side = sides?.new {
                new = try await client.contents(of: side.path, at: side.revision)
            } else {
                new = nil
            }
        }
        return Sources(
            old: old ?? Data(), new: new ?? Data(), fileName: file.fileName,
            oldExists: old != nil, newExists: new != nil)
    }

    /// Thrown by `load` when a file's sources exceed the caller's limit. Nothing was built.
    struct SourcesTooLarge: Error {}

    // swiftlint:disable function_parameter_count
    /// Loads one file's diff, reusing an earlier result without reading when the file's
    /// fingerprint has not changed. Throws read errors, `CancellationError`, and
    /// `SourcesTooLarge` when both sides together exceed `maxSourceBytes`, reused or not.
    ///
    /// A worktree file is stat'ed before reuse, so an edit the watcher has not reported yet
    /// is read. Git sides show the status snapshot, as the sidebar does, until it refreshes.
    static func load(
        _ file: ChangedFile, repository: RepositoryRoot, client: any RepoClient, hideWhitespace: Bool,
        cache: DifftCache, resultCache: DiffResultCache, priority: DifftCache.Priority,
        maxSourceBytes: Int = .max, highlight: @escaping Highlight = defaultHighlight
    ) async throws -> Output {
        let inputs = inputKey(for: file, repository: repository, hideWhitespace: hideWhitespace)
        if let inputs, await worktreeUnchanged(file, client: client),
            let entry = await resultCache.entry(forInputs: inputs)
        {
            guard entry.sourceByteCount <= maxSourceBytes else { throw SourcesTooLarge() }
            return Output(content: .text(entry.document), styles: entry.styles)
        }

        let read: (sources: Sources, matchesFingerprint: Bool)
        do {
            let signposter = PipelineMetrics.signposter
            let readState = signposter.beginInterval("read", id: signposter.makeSignpostID())
            defer { signposter.endInterval("read", readState) }
            if inputs == nil {
                read = (try await sources(for: file, client: client), false)
            } else {
                read = try await verifiedSources(for: file, client: client)
            }
        }
        try Task.checkCancellation()
        // A computation-admission limit, not a memory one: the read has happened, but a
        // huge file costs no diff and no highlighting.
        guard read.sources.old.count + read.sources.new.count <= maxSourceBytes else { throw SourcesTooLarge() }

        let built = try await buildStoring(
            read.sources, hideWhitespace: hideWhitespace, cache: cache, resultCache: resultCache, priority: priority,
            highlight: highlight)
        if let inputs, read.matchesFingerprint, let key = built.storedKey {
            await resultCache.register(key, forInputs: inputs)
        }
        return built.output
    }
    // swiftlint:enable function_parameter_count

    /// The key a file's result is reused under, or nil when status cannot vouch for its
    /// content: an unmerged file, or a working-tree file without a known fingerprint. A
    /// commit's content never changes, so its `id`, which holds the SHA, is enough.
    private static func inputKey(
        for file: ChangedFile, repository: RepositoryRoot, hideWhitespace: Bool
    ) -> DiffResultCache.InputKey? {
        if !file.area.isCommit {
            guard let fingerprint = file.fingerprint, fingerprint.isKnown else { return nil }
        }
        return DiffResultCache.InputKey(
            repository: repository, fileID: file.id, fingerprint: file.fingerprint, hideWhitespace: hideWhitespace)
    }

    /// Whether the worktree file still stats as status saw it. True when the file has no
    /// worktree side.
    private static func worktreeUnchanged(_ file: ChangedFile, client: any RepoClient) async -> Bool {
        guard let expected = file.fingerprint?.worktree, expected != .notApplicable else { return true }
        return await client.worktreeState(of: file.path) == expected
    }

    /// One side of a `verifiedSources` read.
    private struct Side {
        let data: Data?
        /// The bytes are the ones the fingerprint describes.
        let matchesFingerprint: Bool
    }

    /// Reads the same sides as `sources` and says whether the bytes are the ones the
    /// fingerprint describes: git sides are read by blob id, and a worktree file must stat
    /// the same after the read. Blob ids recur (unstage, then restage), so a path read that
    /// raced an index change must never be registered.
    private static func verifiedSources(
        for file: ChangedFile, client: any RepoClient
    ) async throws -> (sources: Sources, matchesFingerprint: Bool) {
        guard let fingerprint = file.fingerprint, !file.area.isCommit, file.kind != .unmerged else {
            return (try await sources(for: file, client: client), file.area.isCommit)
        }
        let old: Side
        let new: Side
        if file.area == .staged {
            old = try await gitSide(fingerprint.old, exists: file.kind != .added, client: client) {
                try await client.headContents(of: file.originalPath ?? file.path)
            }
            new = try await gitSide(fingerprint.new, exists: file.kind != .deleted, client: client) {
                try await client.indexContents(of: file.path)
            }
        } else if file.kind == .untracked {
            old = Side(data: nil, matchesFingerprint: fingerprint.old == .absent)
            new = try await worktreeSide(file.path, expected: fingerprint.worktree, client: client)
        } else {
            // For an unstaged rename, `fingerprint.old` is the index blob at the old path,
            // the same file the path read returns.
            old = try await gitSide(fingerprint.old, exists: true, client: client) {
                try await client.indexContents(of: file.originalPath ?? file.path)
            }
            new =
                file.kind == .deleted
                ? Side(data: nil, matchesFingerprint: true)
                : try await worktreeSide(file.path, expected: fingerprint.worktree, client: client)
        }
        let sources = Sources(
            old: old.data ?? Data(), new: new.data ?? Data(), fileName: file.fileName,
            oldExists: old.data != nil, newExists: new.data != nil)
        return (sources, old.matchesFingerprint && new.matchesFingerprint)
    }

    /// Reads a git side by the fingerprint's blob id. Falls back to a path read, which does
    /// not match the fingerprint, when there is no id or git has no blob for it. A side the
    /// change kind says is missing is not read.
    private static func gitSide(
        _ blob: DiffInputFingerprint.Blob, exists: Bool, client: any RepoClient,
        byPath: () async throws -> Data?
    ) async throws -> Side {
        guard exists else { return Side(data: nil, matchesFingerprint: blob == .absent) }
        // `blobContents` returns nil for a gitlink, whose id is a commit.
        if case let .object(oid) = blob, let data = try await client.blobContents(oid) {
            return Side(data: data, matchesFingerprint: true)
        }
        return Side(data: try await byPath(), matchesFingerprint: false)
    }

    /// Reads a worktree file. It matches the fingerprint only if it stats the same after
    /// the read as it did for status.
    private static func worktreeSide(
        _ path: String, expected: DiffInputFingerprint.Worktree, client: any RepoClient
    ) async throws -> Side {
        let data = try await client.worktreeContents(of: path)
        let after = await client.worktreeState(of: path)
        return Side(data: data, matchesFingerprint: after == expected)
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
        priority: DifftCache.Priority, highlight: @escaping Highlight = defaultHighlight
    ) async throws -> Output {
        try await buildStoring(
            sources, hideWhitespace: hideWhitespace, cache: cache, resultCache: resultCache, priority: priority,
            highlight: highlight
        ).output
    }

    /// `build`, plus the key the result is stored under in `resultCache`, or nil when it
    /// is not stored (binary, identical, or built without difft hints).
    private static func buildStoring(
        _ sources: Sources, hideWhitespace: Bool, cache: DifftCache, resultCache: DiffResultCache,
        priority: DifftCache.Priority, highlight: @escaping Highlight = defaultHighlight
    ) async throws -> (output: Output, storedKey: DiffResultCache.Key?) {
        try Task.checkCancellation()
        if isBinary(sources.old) || isBinary(sources.new) { return (Output(content: .binary, styles: nil), nil) }
        if sources.old == sources.new { return (Output(content: .identical, styles: nil), nil) }

        let difftKey = DifftCache.key(old: sources.old, new: sources.new, fileName: sources.fileName)
        let key = DiffResultCache.Key(difftKey: difftKey, hideWhitespace: hideWhitespace)
        if let entry = await resultCache.entry(for: key) {
            return (Output(content: .text(entry.document), styles: entry.styles), key)
        }

        let oldText = String(decoding: sources.old, as: UTF8.self)
        let newText = String(decoding: sources.new, as: UTF8.self)
        // Split once: the styles and the document share these arrays, so they line up.
        let lines = await Task.detached(priority: .userInitiated) {
            (old: TextLines.split(oldText), new: TextLines.split(newText))
        }.value

        // Highlighting needs only the lines, so it runs while difft does. The sides stay
        // sequential, so a caller processing one file at a time runs one parse at a time,
        // except that a cancelled build returns without waiting for a parse it cannot stop.
        let highlighting = Task {
            let signposter = PipelineMetrics.signposter
            let highlightState = signposter.beginInterval("highlight", id: signposter.makeSignpostID())
            defer { signposter.endInterval("highlight", highlightState) }
            let old = await highlight(lines.old, sources.fileName)
            try Task.checkCancellation()
            let new = await highlight(lines.new, sources.fileName)
            return SyntaxStyles(old: old, new: new)
        }

        // The highlight task is unstructured, so the build's cancellation is forwarded to it.
        return try await withTaskCancellationHandler {
            let signposter = PipelineMetrics.signposter
            let difftState = signposter.beginInterval("difft", id: signposter.makeSignpostID())
            let difft = await cache.result(
                for: difftKey, old: sources.old, new: sources.new, fileName: sources.fileName, priority: priority)
            signposter.endInterval("difft", difftState)
            try Task.checkCancellation()
            let hints = difft?.hints ?? DifftHints()
            let language = difft?.language

            let alignState = signposter.beginInterval("align", id: signposter.makeSignpostID())
            let document = await Task.detached(priority: .userInitiated) {
                let rows = DiffAligner.align(
                    oldLines: lines.old, newLines: lines.new, hideWhitespace: hideWhitespace, hints: hints)
                let moves = MoveDetector.detect(
                    oldLines: lines.old, newLines: lines.new, rows: rows, hideWhitespace: hideWhitespace)
                return DiffDocument(
                    oldLines: lines.old, newLines: lines.new, rows: rows, language: language, moves: moves)
            }.value
            signposter.endInterval("align", alignState)
            try Task.checkCancellation()

            // Cancelled here, this waits for the side being parsed, as before; the other
            // side is skipped.
            let styles = try await highlighting.value

            // Only a successful difft result is kept: `DifftCache` forgets a failure after a
            // while so the fallback document is retried, and this store has no expiry. A
            // result finished after cancellation is still kept: it is valid and the next
            // load hits; the caller decides whether to publish it.
            guard difft != nil else { return (Output(content: .text(document), styles: styles), nil) }
            let entry = DiffResultCache.Entry(
                document: document, styles: styles, sourceByteCount: sources.old.count + sources.new.count)
            await resultCache.store(entry, for: key)
            return (Output(content: .text(document), styles: styles), key)
        } onCancel: {
            highlighting.cancel()
        }
    }

    static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }
}
