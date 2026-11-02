import AppKit

extension DebugLaunchOptions {
    /// A picker popover's window while it is up: a child of `window` hosting a picker's
    /// container, or a SwiftUI popover (GitHub, repository picker), which has no container to find.
    @MainActor
    static func pickerWindow(of window: NSWindow) -> NSWindow? {
        let candidates = (window.childWindows ?? []) + NSApp.windows
        let environment = ProcessInfo.processInfo.environment
        let wantsSwiftUIPopover =
            environment["DIFFVIEWER_GITHUB_POPOVER"] == "1" || environment["DIFFVIEWER_REPOSITORY_PICKER"] == "1"
        return candidates.first { candidate in
            guard candidate.isVisible, let content = candidate.contentView else { return false }
            if wantsSwiftUIPopover, candidate !== window, String(describing: type(of: candidate)).contains("Popover") {
                return true
            }
            return content.descendant(CommitPickerContainerView.self) != nil
                || content.descendant(BranchPickerContainerView.self) != nil
                || content.descendant(StashPickerContainerView.self) != nil
        }
    }
}
