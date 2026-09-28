import Foundation

/// A table bounded by entry count and total cost that evicts the least recently used
/// entry first.
///
/// A hit, or an insert of a key already stored, counts as a use; a miss changes nothing.
/// Zero `entries` or `bytes` retains nothing. A key already stored keeps its first value.
/// A value costing more than `min(maxEntryCost, bytes)` is rejected before anything is
/// evicted, so it never flushes the table only to be dropped itself.
struct CostBoundedLRU<Key: Hashable, Value> {
    enum Insertion: Equatable {
        case stored(evicted: Int)
        case skipped
        case rejected
    }

    private struct Stored {
        let value: Value
        let cost: Int
    }

    private let entries: Int
    private let bytes: Int
    private let maxEntryCost: Int
    private var table: [Key: Stored] = [:]
    /// Keys of `table`, least recently used first. A linear scan is fine at these sizes.
    private var order: [Key] = []
    private var totalCost = 0

    init(entries: Int, bytes: Int, maxEntryCost: Int) {
        precondition(entries >= 0 && bytes >= 0 && maxEntryCost >= 0, "limits must be non-negative")
        self.entries = entries
        self.bytes = bytes
        self.maxEntryCost = maxEntryCost
    }

    var count: Int { table.count }
    var isEmpty: Bool { table.isEmpty }

    mutating func value(for key: Key) -> Value? {
        guard let stored = table[key] else { return nil }
        markUsed(key)
        return stored.value
    }

    /// Storing a key again means its content was just rebuilt, so it counts as a use.
    mutating func insert(_ value: Value, cost: Int, for key: Key) -> Insertion {
        // A negative cost would let the table grow past its byte budget.
        precondition(cost >= 0, "cost must be non-negative")
        guard entries > 0, bytes > 0 else { return .skipped }
        guard table[key] == nil else {
            markUsed(key)
            return .skipped
        }
        guard cost <= min(maxEntryCost, bytes) else { return .rejected }
        table[key] = Stored(value: value, cost: cost)
        order.append(key)
        totalCost += cost
        var evicted = 0
        while table.count > entries || totalCost > bytes, !order.isEmpty {
            if let leastRecent = table.removeValue(forKey: order.removeFirst()) {
                totalCost -= leastRecent.cost
                evicted += 1
            }
        }
        return .stored(evicted: evicted)
    }

    private mutating func markUsed(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.append(order.remove(at: index))
    }
}
