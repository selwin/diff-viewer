import Foundation
import os

/// Timing probes for the load, highlight and render paths.
///
/// Every `measure` emits an os_signpost interval under Points of Interest, so a trace in
/// Instruments shows the stages on the timeline. When a recorder is running, as it is in
/// the benchmark tests, durations are also summed per stage so they can be reported.
/// With no recorder the probes cost one flag read plus the signpost, which is a no-op
/// unless Instruments is recording.
enum PerfProbe {
    struct Stat: Sendable {
        var nanoseconds: UInt64 = 0
        var count = 0
        var maxNanoseconds: UInt64 = 0

        var milliseconds: Double { Double(nanoseconds) / 1_000_000 }
    }

    nonisolated(unsafe) static let signposter = OSSignposter(
        subsystem: "com.selwin.DiffViewer", category: .pointsOfInterest)

    /// Read without the lock on hot paths; set only while no measured work is running.
    nonisolated(unsafe) private(set) static var isRecording = false
    private static let stats = OSAllocatedUnfairLock<[String: Stat]>(initialState: [:])

    static func startRecording() {
        stats.withLock { $0 = [:] }
        isRecording = true
    }

    @discardableResult
    static func stopRecording() -> [String: Stat] {
        isRecording = false
        return stats.withLock { $0 }
    }

    /// Monotonic nanoseconds, cheap enough to read per match or per row.
    @inline(__always)
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Adds `nanoseconds` over `count` occurrences to `stage`.
    static func record(_ stage: String, nanoseconds: UInt64, count: Int = 1) {
        guard isRecording else { return }
        stats.withLock { all in
            var stat = all[stage] ?? Stat()
            stat.nanoseconds += nanoseconds
            stat.count += count
            stat.maxNanoseconds = max(stat.maxNanoseconds, nanoseconds / UInt64(max(count, 1)))
            all[stage] = stat
        }
    }

    /// Records a plain counter (matches, captures, lines) under `stage`.
    static func count(_ stage: String, _ value: Int) {
        guard isRecording else { return }
        stats.withLock { $0[stage, default: Stat()].count += value }
    }

    static func measure<T>(_ stage: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(stage, id: signposter.makeSignpostID())
        defer { signposter.endInterval(stage, state) }
        guard isRecording else { return try body() }
        let start = now()
        defer { record("\(stage)", nanoseconds: now() - start) }
        return try body()
    }

    static func measureAsync<T>(_ stage: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(stage, id: signposter.makeSignpostID())
        defer { signposter.endInterval(stage, state) }
        guard isRecording else { return try await body() }
        let start = now()
        defer { record("\(stage)", nanoseconds: now() - start) }
        return try await body()
    }
}
