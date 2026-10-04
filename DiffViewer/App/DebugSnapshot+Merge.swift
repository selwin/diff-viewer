import Foundation

extension DebugLaunchOptions {
    /// Applies `DIFFVIEWER_BRANCH_PICKER_TAB=merge`, so the picker opens on the Merge… tab,
    /// `DIFFVIEWER_MERGE_SHEET` and `DIFFVIEWER_HEAD_ACTIVITY`. Runs before the other overlays
    /// are presented.
    @MainActor
    static func applyMergeOptions(env: [String: String], in windowState: WindowState) async {
        if env["DIFFVIEWER_BRANCH_PICKER_TAB"] == "merge" { windowState.branchPickerTab = .merge }
        await openMergeSheet(env: env, in: windowState)
        #if DEBUG
            showHeadChangeActivity(env: env, in: windowState)
        #endif
    }

    #if DEBUG
        /// Applies `DIFFVIEWER_HEAD_ACTIVITY=running|merged|fastForwarded|upToDate|created|switched|conflicts`:
        /// shows that sample on the branch pill and leaves it there. `DIFFVIEWER_HEAD_ACTIVITY_NAME`
        /// replaces the sample's branch name, to try a long one. An unknown value does nothing.
        @MainActor
        private static func showHeadChangeActivity(env: [String: String], in windowState: WindowState) {
            guard let sample = env["DIFFVIEWER_HEAD_ACTIVITY"] else { return }
            let override = env["DIFFVIEWER_HEAD_ACTIVITY_NAME"].flatMap { $0.isEmpty ? nil : $0 }
            let current: String
            if case let .named(name)? = windowState.headState { current = name } else { current = "main" }
            let state: HeadChangeActivity.State
            switch sample {
            case "running": state = .running(.switchTo(override ?? current))
            case "merged":
                state = .finished(.merged(source: override ?? "fix/x", kind: .mergeCommit, commitCount: 4))
            case "fastForwarded":
                state = .finished(.merged(source: override ?? "fix/x", kind: .fastForward, commitCount: 4))
            case "upToDate":
                state = .finished(.merged(source: override ?? "fix/x", kind: .alreadyUpToDate, commitCount: nil))
            case "created": state = .finished(.created(override ?? "feature/y"))
            case "switched": state = .finished(.switched(to: override ?? "main"))
            case "conflicts":
                state = .finished(.mergeStopped(source: override ?? "fix/x", conflictFileCount: 2))
            default: return
            }
            windowState.showHeadChangeActivityForSnapshot(state)
        }
    #endif

    /// Applies `DIFFVIEWER_MERGE_SHEET`: opens the Merge sheet for that branch once the
    /// branch list has loaded. Does nothing when no such branch exists or HEAD is not on a
    /// listed branch.
    @MainActor
    private static func openMergeSheet(env: [String: String], in windowState: WindowState) async {
        guard let name = env["DIFFVIEWER_MERGE_SHEET"], !name.isEmpty else { return }
        for _ in 0..<50 where windowState.branchReadStatus != .loaded {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard case let .named(into)? = windowState.headState,
            let head = windowState.branches.first(where: { $0.name == into })
        else { return }
        let target: MergeTarget
        if let branch = windowState.branches.first(where: { $0.name == name && $0.name != into }) {
            target = .local(branch, destinationBranch: into, destinationTipSha: head.tipSha)
        } else if let branch = windowState.remoteBranches.first(where: { "\($0.remote)/\($0.name)" == name }) {
            target = .remote(branch, destinationBranch: into, destinationTipSha: head.tipSha)
        } else {
            return
        }
        windowState.openMergeSheetFromPicker(target)
    }
}
