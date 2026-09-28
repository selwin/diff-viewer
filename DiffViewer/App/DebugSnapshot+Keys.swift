import AppKit

/// Building the key events `DIFFVIEWER_KEYS` sends.
extension DebugLaunchOptions {
    /// The characters a real key press with `code` carries; empty for keys not listed.
    static func characters(forKeyCode code: UInt16) -> String {
        let scalar: Int? =
            switch code {
            case 126: NSUpArrowFunctionKey
            case 125: NSDownArrowFunctionKey
            case 115: NSHomeFunctionKey
            case 119: NSEndFunctionKey
            case 36, 76: 0x0D
            case 53: 0x1B
            default: nil
            }
        return scalar.flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? ""
    }

    /// ⌘ plus `characters`, offered where `NSApplication` offers a key equivalent: the
    /// window's views first, then the main menu. Waits a moment for what it opened.
    @MainActor
    static func sendCommandKey(_ characters: String, to window: NSWindow) async {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)
        else { return }
        if !window.performKeyEquivalent(with: event) { _ = NSApp.mainMenu?.performKeyEquivalent(with: event) }
        try? await Task.sleep(for: .milliseconds(300))
    }
}
