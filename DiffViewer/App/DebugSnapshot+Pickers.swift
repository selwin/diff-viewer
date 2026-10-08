import AppKit

extension DebugLaunchOptions {
    /// A picker popover's window while it is up: a child of `window` hosting a picker's
    /// container.
    @MainActor
    static func pickerWindow(of window: NSWindow) -> NSWindow? {
        let candidates = (window.childWindows ?? []) + NSApp.windows
        return candidates.first { candidate in
            guard candidate.isVisible, let content = candidate.contentView else { return false }
            return content.descendant(CommitPickerContainerView.self) != nil
                || content.descendant(BranchPickerContainerView.self) != nil
                || content.descendant(StashPickerContainerView.self) != nil
        }
    }
}
