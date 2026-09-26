import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import DiffViewer

/// Polls `condition` for up to two seconds.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A working-tree file carries a deterministic fingerprint derived from its path, area and
/// kind, known for every kind but `.unmerged`, whose `old` is `.unknown` as the parser
/// leaves it. A commit-scope file has none, as the real client produces.
func changedFile(_ path: String, area: ChangedFile.Area = .unstaged, kind: ChangedFile.Kind = .modified) -> ChangedFile
{
    ChangedFile(path: path, originalPath: nil, kind: kind, area: area, fingerprint: fingerprint(path, area, kind))
}

private func fingerprint(_ path: String, _ area: ChangedFile.Area, _ kind: ChangedFile.Kind) -> DiffInputFingerprint? {
    let stat = DiffInputFingerprint.Worktree.file(mtimeNs: 1, ctimeNs: 1, size: 10, inode: 1)
    switch (area, kind) {
    case (.commit, _):
        return nil
    case (.staged, _):
        return DiffInputFingerprint(
            old: .object(objectID("head-\(path)")), new: .object(objectID("index-\(path)")),
            worktree: .notApplicable, kind: kind, originalPath: nil)
    case (.unstaged, .untracked):
        return DiffInputFingerprint(old: .absent, new: .notApplicable, worktree: stat, kind: kind, originalPath: nil)
    case (.unstaged, .unmerged):
        return DiffInputFingerprint(old: .unknown, new: .notApplicable, worktree: stat, kind: kind, originalPath: nil)
    case (.unstaged, _):
        return DiffInputFingerprint(
            old: .object(objectID("index-\(path)")), new: .notApplicable, worktree: stat, kind: kind,
            originalPath: nil)
    }
}

extension ChangedFile {
    /// The same file after a worktree write: the stat moved, so `mayHaveChanged` is true.
    func edited() -> ChangedFile {
        guard let fingerprint, case let .file(mtime, ctime, size, inode) = fingerprint.worktree else { return self }
        let worktree = DiffInputFingerprint.Worktree.file(
            mtimeNs: mtime + 1, ctimeNs: ctime + 1, size: size + 1, inode: inode)
        return with(fingerprint: fingerprint.with(worktree: worktree))
    }

    /// The same staged file after another `git add`: the index blob moved, so
    /// `mayHaveChanged` is true. The unstaged counterpart is `edited()`.
    func restaged() -> ChangedFile {
        guard let fingerprint, area == .staged else { return self }
        let moved = DiffInputFingerprint(
            old: fingerprint.old, new: .object(objectID("index2-\(path)")), worktree: fingerprint.worktree,
            kind: fingerprint.kind, originalPath: fingerprint.originalPath)
        return with(fingerprint: moved)
    }
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
    committedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> CommitSummary {
    CommitSummary(
        sha: objectID(seed),
        shortSha: String(objectID(seed).prefix(7)),
        parents: parents ?? [objectID("\(seed)-parent")],
        subject: subject,
        committedAt: committedAt
    )
}

// MARK: Branches

func localBranch(
    _ name: String,
    upstream: BranchUpstream? = nil,
    tipSha: String = objectID("tip"),
    tipCommittedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> LocalBranch {
    LocalBranch(name: name, upstream: upstream, tipSha: tipSha, tipCommittedAt: tipCommittedAt)
}

/// `remoteRef` defaults to the branch half of `shortName`: `origin/main` tracks
/// `refs/heads/main`. `localRef` defaults to `refs/remotes/<shortName>`.
func upstream(
    _ shortName: String,
    remote: String = "origin",
    remoteRef: String? = nil,
    localRef: String? = nil,
    tracking: UpstreamTracking = .counts(ahead: 0, behind: 0)
) -> BranchUpstream {
    let branch = shortName.hasPrefix(remote + "/") ? String(shortName.dropFirst(remote.count + 1)) : shortName
    return BranchUpstream(
        shortName: shortName, remote: remote, remoteRef: remoteRef ?? "refs/heads/\(branch)",
        localRef: localRef ?? "refs/remotes/\(shortName)", tracking: tracking)
}

// MARK: Images

private struct ImageFixtureFailure: Error {
    let step: String
}

/// A solid-colour image of the given size, encoded as `type`. `properties` are passed to
/// the destination, e.g. `kCGImagePropertyOrientation`.
func imageData(width: Int, height: Int, type: UTType = .png, properties: [CFString: Any] = [:]) throws -> Data {
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ImageFixtureFailure(step: "context") }
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { throw ImageFixtureFailure(step: "makeImage") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
        throw ImageFixtureFailure(step: "destination")
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw ImageFixtureFailure(step: "finalize") }
    return data as Data
}
