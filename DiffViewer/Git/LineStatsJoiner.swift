import Foundation

/// Joins numstat rows onto a status list. Untracked files have no numstat row, so their
/// lines are counted from the worktree instead.
enum LineStatsJoiner {
    /// At most this many worktree reads run at once.
    private static let readLimit = 8

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
    /// already counted keep their stats and the remaining untracked files stay nil.
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
                return file.with(lineStats: rows[Key(area: file.area, path: file.path)] ?? .counted(added: 0, deleted: 0))
            }
        }

        let untrackedIndices = result.indices.filter { result[$0].kind == .untracked }
        guard !untrackedIndices.isEmpty else { return result }

        let paths = untrackedIndices.map { result[$0].path }
        for (pathIndex, stats) in await countUntracked(paths: paths, client: client) {
            result[untrackedIndices[pathIndex]] = result[untrackedIndices[pathIndex]].with(lineStats: stats)
        }
        return result
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
        guard let data = await client.worktreeContents(of: path) else { return nil }
        if DiffEngine.isBinary(data) { return .binary }
        return .counted(added: lineCount(data), deleted: 0)
    }
}
