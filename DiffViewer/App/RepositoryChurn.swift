import Foundation

/// How much uncommitted work a repository holds, for its tab and the commit picker's
/// Working Tree row.
struct RepositoryChurn: Equatable, Sendable {
    /// Distinct changed paths: a file both staged and unstaged counts once.
    let changedFileCount: Int
    /// Line counts summed the way the All changes row sums them: a path in both areas
    /// counts twice, and binaries and uncounted files add nothing.
    let added: Int
    let deleted: Int

    init(changedFileCount: Int, added: Int, deleted: Int) {
        self.changedFileCount = changedFileCount
        self.added = added
        self.deleted = deleted
    }

    /// The churn of a working-tree list, with whatever line counts its files carry.
    init(_ changed: [ChangedFile]) {
        changedFileCount = Set(changed.map(\.path)).count
        if case let .counted(added, deleted)? = LineStats.total(of: changed) {
            self.added = added
            self.deleted = deleted
        } else {
            added = 0
            deleted = 0
        }
    }

    /// What the tab shows, one string per number: "+120", "−45", in the sidebar's
    /// wording, which leaves out a side that did not change. When both totals are zero
    /// (binaries, or edits numstat counts as nothing), the file count. Empty for a clean
    /// repository.
    var tabParts: [String] {
        guard changedFileCount > 0 else { return [] }
        let lines = lineParts
        return lines.isEmpty ? [changedFileCount == 1 ? "1 file" : "\(changedFileCount) files"] : lines
    }

    /// The tab's tooltip and accessibility text: "7 files changed · +120 −45".
    var summary: String {
        let changed = changedFileCount == 1 ? "1 file changed" : "\(changedFileCount) files changed"
        let lines = lineParts
        return lines.isEmpty ? changed : "\(changed) · \(lines.joined(separator: " "))"
    }

    private var lineParts: [String] {
        [added > 0 ? "+\(added)" : nil, deleted > 0 ? "−\(deleted)" : nil].compactMap { $0 }
    }
}
