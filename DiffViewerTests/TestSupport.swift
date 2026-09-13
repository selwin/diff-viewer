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
