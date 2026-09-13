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
