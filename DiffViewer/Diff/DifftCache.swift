import CryptoKit
import Foundation

/// The part of a difft run worth keeping: alignment hints and the language name.
/// Token text from the JSON is dropped so cached entries stay small.
struct DifftResult: Sendable {
    let hints: DifftHints
    let language: String

    init(hints: DifftHints, language: String) {
        self.hints = hints
        self.language = language
    }

    init(file: DifftFile) {
        self.init(hints: DifftHints(file: file), language: file.language)
    }

    /// Approximate payload size in bytes, used for the cache budget. Counts ranges,
    /// pairs, and per-line dictionary entries; not a precise memory ceiling.
    var cost: Int {
        let ranges = hints.oldChanges.values.reduce(0) { $0 + $1.count }
            + hints.newChanges.values.reduce(0) { $0 + $1.count }
        let lines = hints.oldChanges.count + hints.newChanges.count
        return (hints.pairs.count + ranges) * 16 + lines * 32 + language.utf8.count
    }
}

/// Memoizes difft runs by file content and schedules every difft process in the app.
///
/// Background (prefetch) runs share a fixed number of slots; foreground runs start
/// immediately, and a foreground request for a key still waiting for a slot is
/// promoted so it launches next. Requests for a key already running await that run
/// rather than starting another process. Completed results live in a bounded table;
/// failures are remembered briefly so a broken file is not retried on every click.
actor DifftCache {
    enum Priority: Sendable {
        case foreground
        case background
    }

    typealias Runner = @Sendable (_ old: Data, _ new: Data, _ fileName: String, _ qualityOfService: QualityOfService) async throws -> DifftFile

    /// `backgroundProcesses` must be positive. Zero `entries` or `bytes` disables
    /// result retention (every request runs difft); zero `failures` disables failure
    /// memory.
    struct Limits: Sendable {
        var backgroundProcesses = 3
        var entries = 256
        var bytes = 8_000_000
        /// Results costing more than this are returned but not stored.
        var maxResultCost = 1_000_000
        var failures = 64
        var failureExpiry: Duration = .seconds(30)
    }

    struct Stats: Sendable, Equatable {
        /// Completed results served from the table.
        var hits = 0
        /// Requests that attached to a run already in flight.
        var inFlightJoins = 0
        /// Requests answered by a remembered failure.
        var failureHits = 0
        var misses = 0
        /// Processes started (admission succeeded).
        var launches = 0
        /// Background requests that had to queue for a slot.
        var backgroundQueueWaits = 0
        var promotions = 0
        var evictions = 0
        var failures = 0
    }

    struct Key: Hashable, Sendable {
        fileprivate let digest: Data
    }

    private struct Admission: Sendable {
        let qualityOfService: QualityOfService
        let countsAsBackground: Bool

        static let foreground = Admission(qualityOfService: .userInitiated, countsAsBackground: false)
        static let background = Admission(qualityOfService: .utility, countsAsBackground: true)
    }

    private struct Entry {
        let task: Task<DifftResult?, Never>
        /// The task has asked for admission (it may be running or queued).
        var admissionStarted = false
        /// A foreground request arrived before admission; launch as foreground.
        var promoted = false
    }

    private struct Stored {
        let result: DifftResult
        let cost: Int
    }

    private struct Failure {
        let reason: String
        let at: ContinuousClock.Instant
    }

    private struct Waiter {
        let key: Key
        let continuation: CheckedContinuation<Admission, Never>
    }

    private let runner: Runner
    private let limits: Limits
    /// Monotonic, so failure expiry is unaffected by wall-clock changes.
    private let now: @Sendable () -> ContinuousClock.Instant

    private var inFlight: [Key: Entry] = [:]
    private var results: [Key: Stored] = [:]
    /// Keys of `results`, oldest first.
    private var resultOrder: [Key] = []
    private var resultBytes = 0
    private var failures: [Key: Failure] = [:]
    /// Keys of `failures`, oldest first.
    private var failureOrder: [Key] = []
    private var waiters: [Waiter] = []
    private var runningBackground = 0
    private(set) var stats = Stats()

    /// Remembered failures, expired or not. For tests.
    var rememberedFailureCount: Int { failures.count }

    init(runner: @escaping Runner, limits: Limits = Limits(), now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        precondition(limits.backgroundProcesses > 0, "backgroundProcesses must be positive")
        precondition(limits.entries >= 0 && limits.bytes >= 0 && limits.maxResultCost >= 0 && limits.failures >= 0, "limits must be non-negative")
        precondition(limits.failureExpiry >= .zero, "failureExpiry must be non-negative")
        self.runner = runner
        self.limits = limits
        self.now = now
    }

    /// The bundled difft binary.
    static func bundled() -> DifftCache {
        DifftCache(runner: { old, new, fileName, qualityOfService in
            try await DifftRunner.run(old: old, new: new, fileName: fileName, qualityOfService: qualityOfService)
        })
    }

    /// Content hash of both sides plus the file name (difft picks its grammar from it).
    nonisolated static func key(old: Data, new: Data, fileName: String) -> Key {
        var hasher = SHA256()
        hasher.update(data: Data(fileName.utf8))
        for data in [old, new] {
            withUnsafeBytes(of: UInt64(data.count).littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: data)
        }
        return Key(digest: Data(hasher.finalize()))
    }

    /// Hints for the pair, running difft if needed. Nil when difft failed.
    nonisolated func result(old: Data, new: Data, fileName: String, priority: Priority) async -> DifftResult? {
        let key = Self.key(old: old, new: new, fileName: fileName)
        return await lookup(key, old: old, new: new, fileName: fileName, priority: priority)
    }

    private func lookup(_ key: Key, old: Data, new: Data, fileName: String, priority: Priority) async -> DifftResult? {
        if let hit = results[key] {
            stats.hits += 1
            return hit.result
        }
        if let failure = failures[key] {
            if now() - failure.at < limits.failureExpiry {
                stats.failureHits += 1
                return nil
            }
            failures[key] = nil
        }
        if let entry = inFlight[key] {
            stats.inFlightJoins += 1
            if priority == .foreground { promote(key) }
            return await entry.task.value
        }

        stats.misses += 1
        let runner = runner
        let task = Task(priority: priority == .foreground ? .userInitiated : .utility) {
            let admission = await self.admit(key, priority: priority)
            var outcome: DifftResult?
            var failure: String?
            do {
                outcome = DifftResult(file: try await runner(old, new, fileName, admission.qualityOfService))
            } catch is CancellationError {
                // Not a difft failure; leave nothing behind so the next request retries.
            } catch {
                failure = error.localizedDescription
            }
            self.finish(key, admission: admission, outcome: outcome, failure: failure)
            return outcome
        }
        inFlight[key] = Entry(task: task)
        return await task.value
    }

    // MARK: - Admission

    private func admit(_ key: Key, priority: Priority) async -> Admission {
        inFlight[key]?.admissionStarted = true
        if priority == .foreground || inFlight[key]?.promoted == true {
            stats.launches += 1
            return .foreground
        }
        if runningBackground < limits.backgroundProcesses {
            runningBackground += 1
            stats.launches += 1
            return .background
        }
        stats.backgroundQueueWaits += 1
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(key: key, continuation: continuation))
        }
    }

    /// Lets a request that is still waiting for a background slot launch now, as
    /// foreground work. Already-running requests are left alone.
    private func promote(_ key: Key) {
        if let index = waiters.firstIndex(where: { $0.key == key }) {
            let waiter = waiters.remove(at: index)
            stats.promotions += 1
            stats.launches += 1
            waiter.continuation.resume(returning: .foreground)
        } else if let entry = inFlight[key], !entry.admissionStarted, !entry.promoted {
            inFlight[key]?.promoted = true
            stats.promotions += 1
        }
    }

    private func finish(_ key: Key, admission: Admission, outcome: DifftResult?, failure: String?) {
        inFlight[key] = nil
        if admission.countsAsBackground {
            if waiters.isEmpty {
                runningBackground -= 1
            } else {
                stats.launches += 1
                waiters.removeFirst().continuation.resume(returning: .background)
            }
        }
        if let outcome {
            store(key, outcome)
        } else if let failure {
            remember(key, failure: failure)
        }
    }

    // MARK: - Failures

    /// Records a failure, dropping expired ones and then the oldest beyond the bound.
    private func remember(_ key: Key, failure reason: String) {
        stats.failures += 1
        NSLog("difft failed: \(reason)")
        let current = now()
        failureOrder.removeAll { candidate in
            guard let failure = failures[candidate], candidate != key else { return true }
            if current - failure.at < limits.failureExpiry { return false }
            failures[candidate] = nil
            return true
        }
        while failures.count >= limits.failures, !failureOrder.isEmpty {
            failures[failureOrder.removeFirst()] = nil
        }
        guard limits.failures > 0 else { return }
        failures[key] = Failure(reason: reason, at: current)
        failureOrder.append(key)
    }

    // MARK: - Results

    private func store(_ key: Key, _ result: DifftResult) {
        let cost = result.cost
        guard cost <= limits.maxResultCost else { return }
        results[key] = Stored(result: result, cost: cost)
        resultOrder.append(key)
        resultBytes += cost
        while results.count > limits.entries || resultBytes > limits.bytes, !resultOrder.isEmpty {
            let oldest = resultOrder.removeFirst()
            if let evicted = results.removeValue(forKey: oldest) {
                resultBytes -= evicted.cost
                stats.evictions += 1
            }
        }
    }
}
