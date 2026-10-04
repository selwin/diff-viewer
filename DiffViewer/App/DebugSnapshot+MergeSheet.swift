import Foundation

extension DebugLaunchOptions {
    /// Applies `DIFFVIEWER_MERGE_SHEET`: opens the Merge sheet for that branch once the
    /// branch list has loaded. Does nothing when no such branch exists or HEAD is not on a
    /// listed branch.
    @MainActor
    static func openMergeSheet(env: [String: String], in windowState: WindowState) async {
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
