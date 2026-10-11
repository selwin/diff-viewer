import AppKit

/// Persists repository-window geometry as the user moves and resizes, so it survives a
/// process killed without quitting (Xcode's Run, a crash).
@MainActor
final class WindowFrameStore {
    private static let key = "repositoryWindowFrame"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// A full-screen frame would come back as a plain screen-sized window; the resize on
    /// leaving full screen saves the windowed frame again.
    func save(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        defaults.set(window.frameDescriptor, forKey: Self.key)
    }

    /// AppKit moves a frame from a disconnected display back onto a screen.
    func restore(_ window: NSWindow) {
        guard let descriptor = defaults.string(forKey: Self.key) else { return }
        window.setFrame(from: descriptor)
    }
}
