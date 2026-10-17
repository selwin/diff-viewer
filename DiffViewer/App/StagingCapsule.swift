import Foundation

/// What the floating staging capsule offers: Stage All with no file selected, or staging
/// or unstaging the selected rows. The Changes menu runs the same action, so the capsule's
/// shortcut is the menu item's.
struct StagingCapsule: Equatable {
    enum Action: Equatable {
        case stageAll
        case stage
        case unstage
    }

    let action: Action
    let files: [ChangedFile]

    /// "Stage All", "Stage 1 File", "Unstage 3 Files".
    var title: String {
        switch action {
        case .stageAll: "Stage All"
        case .stage: "Stage \(fileCount)"
        case .unstage: "Unstage \(fileCount)"
        }
    }

    var shortcut: String {
        switch action {
        // One button, one shortcut: Stage All and Stage N Files are the same control.
        case .stageAll, .stage: "⌘S"
        case .unstage: "⇧⌘S"
        }
    }

    /// The write the capsule runs on `files`.
    var fileAction: FileAction {
        switch action {
        case .stageAll, .stage: .stage
        case .unstage: .unstage
        }
    }

    /// Down into the staging tray, or back up out of it.
    var symbol: String {
        action == .unstage ? "arrow.up" : "arrow.down"
    }

    /// The line counts the capsule shows, so the visible text and the VoiceOver label agree.
    enum Churn: Equatable {
        /// Every target is known and some lines changed.
        case counted(added: Int, deleted: Int)
        /// Every target is known: zero counts, binaries only, or both.
        case noLineChanges
        /// Some target has no counts yet (or never will), so a total would understate.
        case unknown
    }

    var churn: Churn {
        guard files.allSatisfy({ $0.lineStats != nil }) else { return .unknown }
        guard case let .counted(added, deleted)? = LineStats.total(of: files), added > 0 || deleted > 0 else {
            return .noLineChanges
        }
        return .counted(added: added, deleted: deleted)
    }

    /// The title and churn in words; the shortcut is the hint.
    var accessibilityLabel: String {
        switch churn {
        case let .counted(added, deleted):
            let counts = LineStats.counted(added: added, deleted: deleted).spokenCounts ?? ""
            return "\(title), \(counts)"
        case .noLineChanges: return "\(title), no line changes"
        case .unknown: return title
        }
    }

    /// The shortcut in words, since VoiceOver reads the glyphs poorly.
    var spokenShortcut: String {
        switch action {
        case .stageAll, .stage: "Command S"
        case .unstage: "Shift Command S"
        }
    }

    private var fileCount: String {
        files.count == 1 ? "1 File" : "\(files.count) Files"
    }
}

extension WindowState {
    /// The capsule for the current selection, or nil when there is nothing to stage or
    /// unstage. Always nil for a commit, whose files are settled.
    var stagingCapsule: StagingCapsule? {
        guard scope == .workingTree else { return nil }
        let groups = selectedWriteGroups
        if let unstage = groups.first(where: { $0.action == .unstage }) {
            return StagingCapsule(action: .unstage, files: unstage.files)
        }
        if let stage = groups.first(where: { $0.action == .stage }) {
            return StagingCapsule(action: .stage, files: stage.files)
        }
        switch detailSelection {
        case .nothing, .allChanges:
            let files = stageableUnstagedFiles
            return files.isEmpty ? nil : StagingCapsule(action: .stageAll, files: files)
        case .file, .files:
            return nil
        }
    }

    /// The current capsule if a staging action can start and it still offers `action`: the
    /// caller's capsule is from the last render, and the selection may have moved since.
    func stagingCapsule(offering action: StagingCapsule.Action) -> StagingCapsule? {
        guard canStartStagingAction, let capsule = stagingCapsule, capsule.action == action else { return nil }
        return capsule
    }
}
