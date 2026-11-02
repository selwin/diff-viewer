import Foundation

/// The repository picker's rows: this window's repository, then the other open ones in tab
/// order, then recent ones, each once.
struct RepositoryPickerItems: Equatable {
    struct Row: Equatable, Identifiable {
        let root: RepositoryRoot
        let isCurrent: Bool
        /// The digit of the row's ⌘ shortcut: 2 through 9 for the first eight rows other than the
        /// current one, nil after them and for the current row.
        let shortcutDigit: Int?

        var id: RepositoryRoot { root }
    }

    private static let shortcutDigits = 2...9

    let rows: [Row]

    init(current: RepositoryRoot?, open: [RepositoryRoot], recents: [RepositoryRoot]) {
        var seen: Set<RepositoryRoot> = []
        var rows: [Row] = []
        if let current {
            seen.insert(current)
            rows.append(Row(root: current, isCurrent: true, shortcutDigit: nil))
        }
        var nextDigit = Self.shortcutDigits.lowerBound
        for root in open + recents where seen.insert(root).inserted {
            let digit = Self.shortcutDigits.contains(nextDigit) ? nextDigit : nil
            rows.append(Row(root: root, isCurrent: false, shortcutDigit: digit))
            nextDigit += 1
        }
        self.rows = rows
    }
}
