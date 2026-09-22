import Foundation
import Observation

/// App-wide settings, one instance shared by every window. Persisted to `UserDefaults`
/// under the same keys the single-window app used, so existing settings survive.
///
/// Only `hideWhitespace` changes what a diff contains; `collapseUnchanged` and
/// `fontSize` are presentation and are read by the views directly.
@MainActor
@Observable
final class Preferences {
    static let fontSizeRange: ClosedRange<Double> = 9...24
    static let maxRecentRepositories = 10

    var hideWhitespace: Bool {
        didSet {
            defaults.set(hideWhitespace, forKey: Keys.hideWhitespace)
            if hideWhitespace != oldValue { onDiffSettingsChange?() }
        }
    }

    /// Show only change blocks plus context; hidden runs become expandable separators.
    /// Applied in the view layer, so toggling never recomputes a diff.
    var collapseUnchanged: Bool {
        didSet { defaults.set(collapseUnchanged, forKey: Keys.collapseUnchanged) }
    }

    /// Prefer rendered SVG previews when available. Changing this does not recompute
    /// the diff.
    var showsSVGPreview: Bool {
        didSet { defaults.set(showsSVGPreview, forKey: Keys.showsSVGPreview) }
    }

    /// Destructive sidebar actions (Discard Changes, Delete File) ask before running.
    /// The alert's "Don't ask again" box turns this off; the View-menu toggle turns it
    /// back on, which is the only way back — there is no Settings scene.
    var confirmDestructiveFileActions: Bool {
        didSet { defaults.set(confirmDestructiveFileActions, forKey: Keys.confirmDestructiveFileActions) }
    }

    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    /// Most recently opened first.
    private(set) var recentRepositoryRoots: [RepositoryRoot] {
        didSet { defaults.set(recentRepositoryRoots.map(\.path), forKey: Keys.recentRepos) }
    }

    /// Context lines come from the hidden `collapseContextLines` default, validated once.
    let foldOptions: FoldOptions

    /// Called on the main actor after a setting that changes diff content has changed.
    /// Wiring, not state: the single subscriber is whoever fans the change out to windows.
    @ObservationIgnored var onDiffSettingsChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults

    private enum Keys {
        static let recentRepos = "recentRepos"
        static let hideWhitespace = "hideWhitespace"
        static let fontSize = "fontSize"
        static let collapseUnchanged = "collapseUnchanged"
        static let showsSVGPreview = "showsSVGPreview"
        static let collapseContextLines = "collapseContextLines"
        static let confirmDestructiveFileActions = "confirmDestructiveFileActions"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let paths = defaults.stringArray(forKey: Keys.recentRepos) ?? []
        recentRepositoryRoots = paths.map { RepositoryRoot(path: $0) }
        hideWhitespace = defaults.object(forKey: Keys.hideWhitespace) as? Bool ?? true
        let storedSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 12
        fontSize = min(max(storedSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        collapseUnchanged = defaults.object(forKey: Keys.collapseUnchanged) as? Bool ?? true
        showsSVGPreview = defaults.object(forKey: Keys.showsSVGPreview) as? Bool ?? true
        confirmDestructiveFileActions =
            defaults.object(forKey: Keys.confirmDestructiveFileActions) as? Bool ?? true
        foldOptions = FoldOptions.validated(contextLines: defaults.object(forKey: Keys.collapseContextLines) as? Int)
    }

    /// Moves `root` to the front of the recent list.
    func noteOpened(_ root: RepositoryRoot) {
        var roots = recentRepositoryRoots
        roots.removeAll { $0 == root }
        roots.insert(root, at: 0)
        recentRepositoryRoots = Array(roots.prefix(Self.maxRecentRepositories))
    }

    func adjustFontSize(by delta: Double) {
        fontSize = min(max(fontSize + delta, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    func resetFontSize() {
        fontSize = 12
    }
}
