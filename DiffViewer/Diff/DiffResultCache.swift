import Foundation

/// Syntax runs for both sides of one document. Nil means highlighting is unavailable
/// (unsupported language, too large, empty, or parser setup failed).
struct SyntaxStyles: Sendable {
    let old: [[StyleRun]]?
    let new: [[StyleRun]]?
}

/// Remembers finished diffs (document plus styles) by content, so reloading an
/// unchanged file skips alignment and highlighting. A second table maps a file's status
/// fingerprint to a content key, so an unchanged file also skips reading its sources.
actor DiffResultCache {
    /// Default `entries` is at least `ChangesetLimits.maxFiles`, so one changeset fits by
    /// count; custom limits or competing windows can still evict. Zero `entries` or
    /// `bytes` disables retention.
    struct Limits: Sendable {
        var entries = 256
        var bytes = 150_000_000
        /// Entries costing more than this are never stored.
        var maxEntryCost = 20_000_000
        /// How many input keys to remember. Each holds only a content key, so a count bound
        /// is enough.
        var inputKeys = 1024
    }

    struct Key: Hashable, Sendable {
        let difftKey: DifftCache.Key
        let hideWhitespace: Bool
    }

    /// Identifies a file's content by what status reports, without reading it.
    /// `DiffEngine.load` decides which files qualify.
    struct InputKey: Hashable, Sendable {
        let repository: RepositoryRoot
        let fileID: ChangedFile.ID
        let fingerprint: DiffInputFingerprint?
        let hideWhitespace: Bool
    }

    struct Entry: Sendable {
        let document: DiffDocument
        let styles: SyntaxStyles
        /// Estimated retained bytes: the lines, rows, blocks, moves and style runs, not total
        /// app memory.
        let cost: Int
        /// Size of both sources, so a size limit still applies to a reused result.
        let sourceByteCount: Int

        init(document: DiffDocument, styles: SyntaxStyles, sourceByteCount: Int) {
            self.document = document
            self.styles = styles
            self.sourceByteCount = sourceByteCount
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
            total += document.moves.count * MemoryLayout<DiffMove>.stride
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

    /// Lookups by input key. A miss includes a key whose entry has since been evicted.
    struct InputStats: Sendable, Equatable {
        var hits = 0
        var misses = 0
    }

    private var table: CostBoundedLRU<Key, Entry>
    private(set) var stats = Stats()
    /// Every key costs 1, so the byte bound is the count bound.
    private var inputs: CostBoundedLRU<InputKey, Key>
    private(set) var inputStats = InputStats()

    init(limits: Limits = Limits()) {
        table = CostBoundedLRU(entries: limits.entries, bytes: limits.bytes, maxEntryCost: limits.maxEntryCost)
        inputs = CostBoundedLRU(entries: limits.inputKeys, bytes: limits.inputKeys, maxEntryCost: 1)
    }

    var count: Int { table.count }
    var isEmpty: Bool { table.isEmpty }

    func entry(for key: Key) -> Entry? {
        if let entry = table.value(for: key) {
            stats.hits += 1
            return entry
        }
        stats.misses += 1
        return nil
    }

    /// The entry `inputs` were last registered under, if it is still stored. Leaves `stats`
    /// alone: those count content lookups.
    func entry(forInputs inputs: InputKey) -> Entry? {
        if let key = self.inputs.value(for: inputs), let entry = table.value(for: key) {
            inputStats.hits += 1
            return entry
        }
        inputStats.misses += 1
        return nil
    }

    /// Records that `inputs` produce the entry stored under `key`. Call only when the read
    /// is known to match `inputs`; a key already registered keeps its first value.
    func register(_ key: Key, forInputs inputs: InputKey) {
        _ = self.inputs.insert(key, cost: 1, for: inputs)
    }

    /// Storing a key twice is expected: two builds of the same content can overlap — a
    /// cancelled assembler's worker still inside `build`, or two windows.
    func store(_ entry: Entry, for key: Key) {
        switch table.insert(entry, cost: entry.cost, for: key) {
        case let .stored(evicted): stats.evictions += evicted
        case .rejected: stats.rejected += 1
        case .skipped: break
        }
    }
}
