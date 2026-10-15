import Foundation

/// What a filled well shows, in either mode.
struct CompareWellContent: Equatable {
    let title: String
    let subtitle: String?
    /// Drawn in orange, as when the target is the base itself.
    let isWarning: Bool
}

/// What the Compare window's lists, wells and preview say.
extension CompareWindowModel {
    /// The file and line counts of a `.ready` preview.
    struct ChurnCounts: Equatable {
        let files: String
        let added: String
        let deleted: String
    }

    func query(_ side: Side) -> String {
        switch side {
        case .base: baseQuery
        case .target: targetQuery
        }
    }

    /// The refs matching the side's filter, in sort order.
    func rows(_ side: Side) -> [GitRef] {
        let filter = query(side).trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return refs }
        return refs.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    /// Nil while loading or when there are rows to show. A failed read shows in both columns.
    func emptyText(_ side: Side) -> String? {
        switch refList {
        case .loading: return nil
        case let .failed(message): return message
        case .loaded:
            if refs.isEmpty { return "No branches or tags" }
            return rows(side).isEmpty ? "No matches" : nil
        }
    }

    func isCurrentBranch(_ ref: GitRef) -> Bool {
        ref.kind == .local && ref.name == currentBranch
    }

    /// A row's second line.
    func subtitle(for ref: GitRef) -> String {
        let date = grouping.commitDateText(for: ref.committedAt)
        return isCurrentBranch(ref) ? "\(date) · checked out" : date
    }

    /// Nil when the side is empty. Comparing a ref with itself is called out on the target.
    func wellSubtitle(_ side: Side) -> String? {
        guard let ref = selection(side) else { return nil }
        if side == .target, isTargetSameAsBase { return "Same as base" }
        return grouping.commitDateText(for: ref.committedAt)
    }

    /// Nil when the side is empty.
    func wellContent(_ side: Side) -> CompareWellContent? {
        switch mode {
        case .branches:
            guard let ref = selection(side) else { return nil }
            return CompareWellContent(
                title: ref.name, subtitle: wellSubtitle(side), isWarning: side == .target && isTargetSameAsBase)
        case .pullRequest:
            return pullRequest.wellContent(side)
        }
    }

    /// The dashed prompt an empty well shows.
    func wellPlaceholder(_ side: Side) -> (title: String, subtitle: String) {
        switch mode {
        case .branches: (side == .base ? "Choose a base" : "Choose a branch to compare", "Pick one from the list")
        case .pullRequest: pullRequest.wellPlaceholder(side)
        }
    }

    var churnCounts: ChurnCounts? {
        guard case let .ready(summary) = churn else { return nil }
        return ChurnCounts(
            files: MergeSheetModel.filesText(summary.fileCount, locale: locale),
            added: MergeSheetModel.addedText(summary.addedLineCount, locale: locale),
            deleted: MergeSheetModel.deletedText(summary.deletedLineCount, locale: locale))
    }

    /// Nil when the preview draws nothing.
    var churnAccessibilityLabel: String? {
        switch churn {
        case .hidden, .pending: nil
        case .comparing: "Comparing"
        case .noDifferences: "No differences"
        case let .ready(summary): Self.churnAccessibilityLabel(summary, locale: locale)
        case let .failed(message): "Preview unavailable: \(message)"
        }
    }

    static func churnAccessibilityLabel(_ summary: IncomingChangeSummary, locale: Locale) -> String {
        func count(_ value: Int, _ singular: String, _ plural: String) -> String {
            value == 1 ? "1 \(singular)" : "\(value.formatted(.number.locale(locale))) \(plural)"
        }
        return [
            count(summary.fileCount, "file changed", "files changed"),
            count(summary.addedLineCount, "addition", "additions"),
            count(summary.deletedLineCount, "deletion", "deletions"),
        ].joined(separator: ", ")
    }
}
