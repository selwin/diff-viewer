import Foundation

/// The staging tray's words: its header, its commit button, and what VoiceOver reads for
/// each. Built from the staged files alone, so the tray and its tests agree on them.
struct StagingTraySummary: Equatable {
    let fileCountText: String
    let commitTitle: String
    /// The staged lines added and deleted; nil until counts arrive, and for a staged set
    /// with no line counts at all, such as binaries only.
    let churn: LineStats?
    let headerAccessibilityLabel: String
    let commitAccessibilityLabel: String

    init(stagedFiles: [ChangedFile], isMerging: Bool) {
        let count = stagedFiles.count
        fileCountText = FileCountText.make(count)
        // A merge can have nothing staged and still be committed; naming zero files would
        // read as a button that does nothing.
        if isMerging, count == 0 {
            commitTitle = "Commit Merge"
        } else {
            commitTitle = count == 1 ? "Commit 1 File" : "Commit \(count) Files"
        }
        churn = LineStats.total(of: stagedFiles)
        let spokenChurn = churn?.spokenCounts.map { ", \($0)" } ?? ""
        headerAccessibilityLabel = "Staged, \(fileCountText)\(spokenChurn)"
        commitAccessibilityLabel = "\(commitTitle)\(spokenChurn)"
    }
}
