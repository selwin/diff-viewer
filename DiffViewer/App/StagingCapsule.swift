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
        case .stageAll: "⌥⌘S"
        case .stage: "⌘S"
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

    /// The title and the shortcut in words, since VoiceOver reads the glyphs poorly.
    var accessibilityLabel: String {
        let keys =
            switch action {
            case .stageAll: "Option Command S"
            case .stage: "Command S"
            case .unstage: "Shift Command S"
            }
        return "\(title), \(keys)"
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
