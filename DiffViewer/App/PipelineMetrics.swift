import Foundation
import os

/// Counters and signposts for the Debug benchmark; observation only, never a limit.
enum PipelineMetrics {
    struct Counts: Sendable, Equatable {
        var parses = 0
        var shapedLines = 0
        var drawNanoseconds: UInt64 = 0
        var prefetchReads = 0
        var prefetchSkips = 0
    }

    static let signposter = OSSignposter(subsystem: "com.selwin.DiffViewer", category: "Pipeline")

    private static let lock = OSAllocatedUnfairLock(initialState: Counts())

    static var counts: Counts { lock.withLock { $0 } }

    static func countParse() { lock.withLock { $0.parses += 1 } }
    static func countShapedLine() { lock.withLock { $0.shapedLines += 1 } }
    static func addDrawTime(_ nanoseconds: UInt64) { lock.withLock { $0.drawNanoseconds += nanoseconds } }
    static func countPrefetchRead() { lock.withLock { $0.prefetchReads += 1 } }
    static func countPrefetchSkip() { lock.withLock { $0.prefetchSkips += 1 } }
}
