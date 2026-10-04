/// The words a Merge row shows for its preview. A conflict is a warning, so the reader
/// sees it before opening the merge.
enum MergePreviewText {
    static func label(for preview: MergePreview) -> BranchRowLabel {
        switch preview {
        case .alreadyMerged:
            BranchRowLabel(text: "Already merged", style: .secondary)
        case let .clean(commits):
            BranchRowLabel(text: commits == 1 ? "1 commit" : "\(commits) commits", style: .secondary)
        case let .conflicts(_, paths) where paths.isEmpty:
            BranchRowLabel(text: "Conflicts predicted", style: .warning)
        case let .conflicts(_, paths):
            BranchRowLabel(
                text: paths.count == 1 ? "Conflict in 1 file" : "Conflict in \(paths.count) files", style: .warning)
        }
    }
}
