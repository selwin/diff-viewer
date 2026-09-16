import Foundation

@testable import DiffViewer

/// Polls `condition` for up to two seconds.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func changedFile(_ path: String, area: ChangedFile.Area = .unstaged, kind: ChangedFile.Kind = .modified) -> ChangedFile
{
    ChangedFile(path: path, originalPath: nil, kind: kind, area: area)
}

// MARK: Clock

/// A `Clock` the test drives by hand: nothing sleeping on it wakes until `advance` moves
/// its reading past the deadline, so a scheduled flush fires exactly when the test says.
///
/// Named apart from `TestClock` in `DifftCacheTests`, which is a plain "what time is it"
/// source rather than something to sleep on.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        /// Since the clock was created. Only differences matter.
        let offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var cancelled: Set<Int> = []
    private var nextID = 0

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }

    /// How many sleepers are waiting, so a test can tell that a flush has been scheduled.
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    /// Moves the reading forward and wakes everything whose deadline has passed.
    func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = sleepers.filter { $0.deadline <= current }
        sleepers.removeAll { $0.deadline <= current }
        lock.unlock()
        for sleeper in due { sleeper.continuation.resume() }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                // Cancelled before the continuation existed: the handler below left a note.
                if cancelled.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                cancelled.insert(id)
                lock.unlock()
                return
            }
            let sleeper = sleepers.remove(at: index)
            lock.unlock()
            sleeper.continuation.resume(throwing: CancellationError())
        }
    }
}

// MARK: Diff rows

func addedRow(_ new: Int) -> DiffRow {
    DiffRow(kind: .added, old: nil, new: DiffSide(lineIndex: new, highlights: []))
}

func deletedRow(_ old: Int) -> DiffRow {
    DiffRow(kind: .deleted, old: DiffSide(lineIndex: old, highlights: []), new: nil)
}

func modifiedRow(_ old: Int, _ new: Int, highlights: [Range<Int>] = []) -> DiffRow {
    DiffRow(
        kind: .modified,
        old: DiffSide(lineIndex: old, highlights: highlights),
        new: DiffSide(lineIndex: new, highlights: highlights))
}

/// A text diff of `count` aligned rows, modified at the given row indices, with one
/// line per row on each side.
func textContent(rows count: Int, modified: [Range<Int>], language: String? = "Swift") -> DiffContent {
    var changed = IndexSet()
    for range in modified { changed.insert(integersIn: range) }
    let rows = (0..<count).map { changed.contains($0) ? modifiedRow($0, $0) : DiffRow.equal(old: $0, new: $0) }
    let lines = (0..<count).map { "line \($0)" }
    return .text(DiffDocument(oldLines: lines, newLines: lines, rows: rows, language: language))
}

/// A 40-character object id from a short seed, so tests can use readable names where
/// git would use a hash.
func objectID(_ seed: String) -> String {
    let hex = seed.unicodeScalars.map { String(format: "%02x", $0.value & 0xff) }.joined()
    return String((hex + String(repeating: "0", count: 40)).prefix(40))
}

func commitSummary(
    _ seed: String,
    subject: String = "A commit",
    parents: [String]? = nil,
    authorName: String = "Tester",
    authoredAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> CommitSummary {
    CommitSummary(
        sha: objectID(seed),
        shortSha: String(objectID(seed).prefix(7)),
        parents: parents ?? [objectID("\(seed)-parent")],
        subject: subject,
        authorName: authorName,
        authoredAt: authoredAt
    )
}
