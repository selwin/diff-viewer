import AppKit

extension DebugLaunchOptions {
    /// What `DIFFVIEWER_DUMP_WINDOWS` and SIGUSR1 print (see `DebugLaunchOptions`).
    @MainActor
    static func dumpWindows(_ services: AppServices) {
        let coordinator = services.coordinator
        var lines: [String] = ["---"]
        var seenGroups: [NSWindowTabGroup] = []
        for window in NSApp.windows where window.contentView != nil {
            let group = window.tabGroup?.windows.count ?? 1
            let visible = window.occlusionState.contains(.visible)
            lines.append("window title=\(window.title) tabGroup=\(group) key=\(window.isKeyWindow) visible=\(visible)")
            if let tabGroup = window.tabGroup, !seenGroups.contains(where: { $0 === tabGroup }) {
                seenGroups.append(tabGroup)
                lines.append("tabs=\(tabGroup.windows.map(\.title))")
            }
        }
        let states = coordinator.windows.values.map { state in
            "state repo=\(state.repoName) key=\(state.isKey) visible=\(state.isVisible) "
                + "files=\(state.files.count) stale=\(state.diffStale) "
                + "scope=\(state.scopeDisplayTitle) picker=\(state.isCommitPickerPresented) "
                + "branchPicker=\(state.isBranchPickerPresented)"
        }
        lines.append(contentsOf: states.sorted())
        lines.append(
            "openOrder=\(coordinator.openOrder.map(\.name)) "
                + "rootIndex=\(coordinator.rootIndex.keys.map(\.name).sorted()) "
                + "pending=\(coordinator.pendingCreates.count) "
                + "lastActive=\(coordinator.lastActiveRepositoryRoot?.name ?? "nil") "
                + "phase=\(coordinator.phase)"
        )
        let defaults = Self.defaults
        let saved = (defaults.stringArray(forKey: WindowCoordinator.SessionKeys.openRoots) ?? []).map {
            RepositoryRoot(path: $0).name
        }
        let savedActive =
            defaults.string(forKey: WindowCoordinator.SessionKeys.lastActive).map { RepositoryRoot(path: $0).name }
            ?? "nil"
        lines.append("saved=\(saved) savedActive=\(savedActive)")
        let gauge = DifftRunner.processGauge
        lines.append(
            "prefetchWorkersPeak=\(services.prefetcher.peakActiveWorkers) "
                + "difftRunning=\(gauge.running) difftPeak=\(gauge.peak)"
        )
        print(lines.joined(separator: "\n"))
        fflush(stdout)
    }
}
