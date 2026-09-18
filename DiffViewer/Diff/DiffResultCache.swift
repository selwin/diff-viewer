import Foundation

/// Syntax runs for both sides of one document. Nil means highlighting is unavailable
/// (unsupported language, too large, empty, or parser setup failed).
struct SyntaxStyles: Sendable {
    let old: [[StyleRun]]?
    let new: [[StyleRun]]?
}

/// Remembers finished diffs (document plus styles) by content, so reloading an
/// unchanged file skips alignment and highlighting. Get/put only; `DifftCache` is the
/// scheduler.
actor DiffResultCache {
    /// Default `entries` is at least `ChangesetLimits.maxFiles`, so one changeset fits by
    /// count; custom limits or competing windows can still evict. Zero `entries` or
    /// `bytes` disables retention.
    struct Limits: Sendable {
        var entries = 256
        var bytes = 150_000_000
        /// Entries costing more than this are never stored.
        var maxEntryCost = 20_000_000
    }

    struct Key: Hashable, Sendable {
        let difftKey: DifftCache.Key
        let hideWhitespace: Bool
    }

    struct Entry: Sendable {
        let document: DiffDocument
        let styles: SyntaxStyles
        /// Estimated retained bytes: the lines, rows, blocks and style runs, not total
        /// app memory.
        let cost: Int

        init(document: DiffDocument, styles: SyntaxStyles) {
            self.document = document
            self.styles = styles
            cost = Self.cost(of: document) + Self.cost(of: styles.old) + Self.cost(of: styles.new)
        }

        private static func cost(of document: DiffDocument) -> Int {
            var total = 0
            for lines in [document.oldLines, document.newLines] {
                total += lines.count * MemoryLayout<String>.stride
                for line in lines { total += line.utf8.count }
            }
            total += document.rows.count * MemoryLayout<DiffRow>.stride
            for row in document.rows {
                let ranges = (row.old?.highlights.count ?? 0) + (row.new?.highlights.count ?? 0)
                total += ranges * MemoryLayout<Range<Int>>.stride
            }
            total += document.changeBlocks.count * MemoryLayout<Range<Int>>.stride
            return total
        }

        private static func cost(of runs: [[StyleRun]]?) -> Int {
            guard let runs else { return 0 }
            let allowancePerArray = 32
            return runs.reduce(runs.count * allowancePerArray) { $0 + $1.count * MemoryLayout<StyleRun>.stride }
        }
    }

    struct Stats: Sendable, Equatable {
        var hits = 0
        var misses = 0
        var evictions = 0
        /// Entries too large for the table, dropped without evicting anything.
        var rejected = 0
    }

    private let limits: Limits
    private var entries: [Key: Entry] = [:]
    /// Keys of `entries`, oldest first.
    private var order: [Key] = []
    private var bytes = 0
    private(set) var stats = Stats()

    init(limits: Limits = Limits()) {
        precondition(
            limits.entries >= 0 && limits.bytes >= 0 && limits.maxEntryCost >= 0, "limits must be non-negative")
        self.limits = limits
    }

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    func entry(for key: Key) -> Entry? {
        if let entry = entries[key] {
            stats.hits += 1
            return entry
        }
        stats.misses += 1
        return nil
    }

    /// Idempotent: a key already stored keeps its existing entry (two builds of the same
    /// content can overlap — a cancelled assembler's worker still inside `build`, or two
    /// windows). Rejects cost over `min(maxEntryCost, bytes)` before evicting anything,
    /// so a large entry never flushes the table only to be dropped itself; then evicts
    /// oldest first past either budget.
    func store(_ entry: Entry, for key: Key) {
        guard limits.entries > 0, limits.bytes > 0, entries[key] == nil else { return }
        guard entry.cost <= min(limits.maxEntryCost, limits.bytes) else {
            stats.rejected += 1
            return
        }
        entries[key] = entry
        order.append(key)
        bytes += entry.cost
        while entries.count > limits.entries || bytes > limits.bytes, !order.isEmpty {
            let oldest = order.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) {
                bytes -= evicted.cost
                stats.evictions += 1
            }
        }
    }
}
