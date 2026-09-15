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
