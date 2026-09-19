import Foundation

/// Joins numstat rows onto a status list. Untracked files have no numstat row, so their
/// lines are counted from the worktree instead, and binary files get their byte counts
/// from the fingerprint, the worktree, or one `objectSizes` batch.
enum LineStatsJoiner {
    /// At most this many worktree reads run at once.
    private static let readLimit = 8

    /// Where one side's byte count of a binary file comes from.
    enum BinarySizeSource: Equatable {
        /// The side does not exist, so its byte count is nil.
        case absent
        /// A git object to size: a blob id or `<rev>:<path>`.
        case spec(String)
        /// Already known, from a worktree stat.
        case byteCount(Int64)
        /// Cannot be determined; the file keeps `.binary(nil)`.
        case unknown
    }

    private struct Key: Hashable {
        let area: ChangedFile.Area
        let path: String
    }

    /// Attaches numstat rows to `files` by (area, path); untracked files are counted from
    /// the worktree. The result has the same order and count as `files`.
    ///
    /// An area missing from `numstat` means its rows are unknown (git failed), so its files
    /// get nil. An area that is present but has no row for a file means git saw no
    /// difference (a whitespace-only edit under `-w`), which is zero churn.
    ///
    /// Cancelling the surrounding task stops scheduling new worktree reads: the files
    /// already counted keep their stats, the remaining untracked files stay nil, and
    /// binary files keep `.binary(nil)`.
    static func attach(
        numstat: [ChangedFile.Area: [NumstatEntry]],
        to files: [ChangedFile],
        client: any RepoClient
    ) async -> [ChangedFile] {
        var rows: [Key: LineStats] = [:]
        for (area, entries) in numstat {
            for entry in entries {
                // Unmerged paths appear twice; the first row is the real one.
                let key = Key(area: area, path: entry.path)
                if rows[key] == nil { rows[key] = entry.stats }
            }
        }

        var result = files.map { file in
            switch file.kind {
            case .unmerged, .untracked:
                return file.with(lineStats: nil)
            default:
                guard numstat[file.area] != nil else { return file.with(lineStats: nil) }
                return file.with(
                    lineStats: rows[Key(area: file.area, path: file.path)] ?? .counted(added: 0, deleted: 0))
            }
        }

        let untrackedIndices = result.indices.filter { result[$0].kind == .untracked }
        if !untrackedIndices.isEmpty {
            let paths = untrackedIndices.map { result[$0].path }
            for (pathIndex, stats) in await countUntracked(paths: paths, client: client) {
                result[untrackedIndices[pathIndex]] = result[untrackedIndices[pathIndex]].with(lineStats: stats)
            }
        }

        guard !Task.isCancelled else { return result }
        await attachBinarySizes(to: &result, client: client)
        return result
    }

    /// Stamps byte counts onto every file still at `.binary(nil)`. Sides the fingerprint
    /// already answers need no git; the rest are sized in one batch. A file with a spec
    /// git cannot answer stays `.binary(nil)`.
    private static func attachBinarySizes(to result: inout [ChangedFile], client: any RepoClient) async {
        var pending: [(index: Int, old: BinarySizeSource, new: BinarySizeSource)] = []
        var specs: [String] = []
        var seenSpecs: Set<String> = []
        for index in result.indices where result[index].lineStats == .binary(nil) {
            let sources = sizeSources(for: result[index])
            guard sources.old != .unknown, sources.new != .unknown else { continue }
            let needed = [sources.old, sources.new].compactMap { source -> String? in
                if case let .spec(spec) = source { return spec }
                return nil
            }
            if needed.isEmpty {
                // No git needed: both sides are already known.
                if let stats = resolvedBinaryStats(sources, answers: [:]) {
                    result[index] = result[index].with(lineStats: stats)
                }
                continue
            }
            pending.append((index, sources.old, sources.new))
            for spec in needed where seenSpecs.insert(spec).inserted { specs.append(spec) }
        }
        guard !specs.isEmpty else { return }

        // `try?`: sizes are decoration; a failed batch leaves every pending file `.binary(nil)`.
        var answers: [String: Int64] = [:]
        if let sizes = try? await client.objectSizes(of: specs), sizes.count == specs.count {
            for (spec, size) in zip(specs, sizes) {
                if let size { answers[spec] = size }
            }
        }
        for entry in pending {
            guard let stats = resolvedBinaryStats((entry.old, entry.new), answers: answers) else { continue }
            result[entry.index] = result[entry.index].with(lineStats: stats)
        }
    }

    /// `.binary` with both sides resolved, or nil when a spec has no answer.
    private static func resolvedBinaryStats(
        _ sources: (old: BinarySizeSource, new: BinarySizeSource), answers: [String: Int64]
    ) -> LineStats? {
        guard let old = byteCount(of: sources.old, answers: answers),
            let new = byteCount(of: sources.new, answers: answers)
        else { return nil }
        return .binary(BinarySizes(oldByteCount: old, newByteCount: new))
    }

    /// `.some(nil)` for an absent side; nil when the source is unknown or unanswered.
    private static func byteCount(of source: BinarySizeSource, answers: [String: Int64]) -> Int64?? {
        switch source {
        case .absent: .some(nil)
        case let .byteCount(count): count
        case let .spec(spec): if let size = answers[spec] { .some(size) } else { nil }
        case .unknown: nil
        }
    }

    /// Where each side's byte count of a binary file comes from. Working-tree areas read
    /// the status fingerprint: `.absent` is the zero hash or a missing file, exactly "this
    /// side does not exist". A commit sizes `<parent>:<originalPath ?? path>` and
    /// `<sha>:<path>`, skipping the side an added, deleted, or root commit's file lacks.
    static func sizeSources(for file: ChangedFile) -> (old: BinarySizeSource, new: BinarySizeSource) {
        switch file.area {
        case .staged:
            guard let fingerprint = file.fingerprint else { return (.unknown, .unknown) }
            return (source(of: fingerprint.old), source(of: fingerprint.new))
        case .unstaged:
            guard let fingerprint = file.fingerprint else { return (.unknown, .unknown) }
            return (source(of: fingerprint.old), source(of: fingerprint.worktree))
        case let .commit(ref):
            let old: BinarySizeSource =
                switch (file.kind, ref.firstParentSHA) {
                case (.added, _), (_, nil): .absent
                case let (_, parent?): spec(parent, file.originalPath ?? file.path)
                }
            let new: BinarySizeSource = file.kind == .deleted ? .absent : spec(ref.sha, file.path)
            return (old, new)
        }
    }

    private static func source(of blob: DiffInputFingerprint.Blob) -> BinarySizeSource {
        switch blob {
        case let .object(oid): .spec(oid)
        case .absent: .absent
        case .unknown, .notApplicable: .unknown
        }
    }

    private static func source(of worktree: DiffInputFingerprint.Worktree) -> BinarySizeSource {
        switch worktree {
        case let .file(_, _, size, _): .byteCount(size)
        case .missing: .absent
        case .unknown, .notApplicable: .unknown
        }
    }

    /// `<rev>:<path>`, or `.unknown` for a path the line-framed batch cannot carry.
    private static func spec(_ revision: String, _ path: String) -> BinarySizeSource {
        GitClient.breaksLineFraming(path) ? .unknown : .spec("\(revision):\(path)")
    }

    /// Lines in `data` by the same rule as `TextLines.split`: the number of newlines,
    /// plus one if the data is non-empty and does not end in a newline.
    static func lineCount(_ data: Data) -> Int {
        if data.isEmpty { return 0 }
        var count = data.reduce(into: 0) { total, byte in if byte == 0x0A { total += 1 } }
        if data.last != 0x0A { count += 1 }
        return count
    }

    /// Reads each path from the worktree, at most `readLimit` at a time, and returns the
    /// stats keyed by the path's index in `paths`. Cancellation stops scheduling further
    /// reads; whatever was already collected is still returned.
    private static func countUntracked(paths: [String], client: any RepoClient) async -> [(Int, LineStats?)] {
        await withTaskGroup(of: (Int, LineStats?).self) { group in
            var nextPathIndex = 0
            func addTask(_ pathIndex: Int) {
                let path = paths[pathIndex]
                group.addTask { (pathIndex, await stats(of: path, client: client)) }
            }
            while nextPathIndex < min(readLimit, paths.count), !Task.isCancelled {
                addTask(nextPathIndex)
                nextPathIndex += 1
            }

            var counted: [(Int, LineStats?)] = []
            for await result in group {
                counted.append(result)
                if nextPathIndex < paths.count, !Task.isCancelled {
                    addTask(nextPathIndex)
                    nextPathIndex += 1
                }
            }
            return counted
        }
    }

    private static func stats(of path: String, client: any RepoClient) async -> LineStats? {
        // `try?`: a file that cannot be read has unknown counts, exactly as a missing
        // one does. Counting is decoration and must not fail the list.
        guard let data = try? await client.worktreeContents(of: path) else { return nil }
        if DiffEngine.isBinary(data) {
            return .binary(BinarySizes(oldByteCount: nil, newByteCount: Int64(data.count)))
        }
        return .counted(added: lineCount(data), deleted: 0)
    }
}
