import Foundation

extension DebugLaunchOptions {
    /// Applies `DIFFVIEWER_COMPARE=<base>...<target>`: opens a comparison tab beside the
    /// target window and returns it, as the window the rest of the sequence acts on. Nil when
    /// the variable is unset, or after printing why the tab could not open.
    @MainActor
    static func applyComparison(env: [String: String], services: AppServices) async -> WindowState? {
        guard let spec = env["DIFFVIEWER_COMPARE"] else { return nil }
        func failure(_ reason: String) -> WindowState? {
            print("### DIFFVIEWER_COMPARE FAILED: \(reason)")
            fflush(stdout)
            return nil
        }
        let coordinator = services.coordinator
        _ = await eventually { targetState(coordinator) != nil }
        try? await Task.sleep(for: .seconds(0.5))
        let owner = targetState(coordinator)
        let names = spec.components(separatedBy: "...")
        guard names.count == 2 else { return failure("expected <base>...<target>, got \(spec)") }
        guard let owner, let client = coordinator.client(for: owner.id) else {
            return failure("no open repository window to compare in")
        }
        // `commitSha(of:)` runs `rev-parse`, so a bare branch name resolves.
        guard let baseSHA = try? await client.commitSha(of: names[0]) else {
            return failure("\(names[0]) names no commit")
        }
        guard let targetSHA = try? await client.commitSha(of: names[1]) else {
            return failure("\(names[1]) names no commit")
        }
        guard let mergeBaseSHA = try? await client.mergeBase(baseSHA, targetSHA) else {
            return failure("\(names[0]) and \(names[1]) share no history")
        }
        let range = CommitRange(
            baseName: names[0], targetName: names[1], mergeBaseSHA: mergeBaseSHA, targetSHA: targetSHA)
        let existing = Set(coordinator.windows.keys)
        guard coordinator.openComparison(owner: owner.id, range: range) else {
            return failure("\(owner.repoName) cannot own a comparison")
        }
        // Registered and attached, so the sequence can find its `NSWindow`.
        func tab() -> WindowState? {
            coordinator.windows.values.first {
                !existing.contains($0.id) && $0.isComparisonTab && services.windows[$0.id] != nil
            }
        }
        _ = await eventually { tab() != nil }
        return tab() ?? failure("the comparison tab did not register")
    }
}
