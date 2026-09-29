import CryptoKit
import Foundation

/// Memoizes tree-sitter runs by file name and line content.
///
/// A save changes only the working-tree side of a diff, so the index or HEAD side, which
/// is byte-identical, is looked up here instead of parsed again. The same blob also serves
/// the staged and unstaged views and adjacent commits.
actor HighlightCache {
    struct Limits: Sendable {
        var entries = 256
        var bytes = 16_000_000
        /// Results costing more than this, or more than `bytes`, are returned but not stored.
        var maxEntryCost = 4_000_000
    }

    struct Key: Hashable, Sendable {
        fileprivate let digest: Data
    }

    private var results: CostBoundedLRU<Key, [[StyleRun]]>

    init(limits: Limits = Limits()) {
        results = CostBoundedLRU(entries: limits.entries, bytes: limits.bytes, maxEntryCost: limits.maxEntryCost)
    }

    /// Content hash of the lines plus the file name (the grammar is picked from it). Each
    /// piece is length-prefixed so `["ab"]` and `["a", "b"]` differ.
    nonisolated static func key(lines: [String], fileName: String) -> Key {
        var hasher = SHA256()
        func update(_ text: String) {
            var text = text
            withUnsafeBytes(of: UInt64(text.utf8.count).littleEndian) { hasher.update(bufferPointer: $0) }
            text.withUTF8 { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        }
        update(fileName)
        for line in lines { update(line) }
        return Key(digest: Data(hasher.finalize()))
    }

    /// A highlighter that answers from this cache and otherwise runs `fallback`. Nil results
    /// (unsupported language, too large) are not stored. The key is hashed on the caller's
    /// task, not on the actor, so a large file does not block other lookups.
    nonisolated func highlight(fallback: @escaping DiffEngine.Highlight = DiffEngine.defaultHighlight)
        -> DiffEngine.Highlight
    {
        { lines, fileName in
            let key = Self.key(lines: lines, fileName: fileName)
            if let hit = await self.lookup(key) { return hit }
            guard let runs = await fallback(lines, fileName) else { return nil }
            await self.store(runs, lines: lines.count, for: key)
            return runs
        }
    }

    private func lookup(_ key: Key) -> [[StyleRun]]? {
        results.value(for: key)
    }

    private func store(_ runs: [[StyleRun]], lines: Int, for key: Key) {
        let cost = runs.reduce(0) { $0 + $1.count } * 16 + lines * 8
        _ = results.insert(runs, cost: cost, for: key)
    }
}
