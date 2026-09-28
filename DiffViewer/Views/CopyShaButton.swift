import AppKit

/// A small borderless button that copies a commit's full SHA, and shows a checkmark for
/// a moment after it has.
final class CopyShaButton: NSButton {
    static let side: CGFloat = 16

    private static let feedbackDuration: TimeInterval = 1.2
    private static let copyImage = symbol("doc.on.doc")
    private static let copiedImage = symbol("checkmark")

    /// After the copy; the picker returns focus to its search field.
    var onCopy: () -> Void = {}

    /// White on the accent highlight, secondary elsewhere.
    var isOnAccent = false {
        didSet { if isOnAccent != oldValue { applyTint() } }
    }

    private var sha = ""
    private var feedbackTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        image = Self.copyImage
        target = self
        action = #selector(copySha)
        toolTip = "Copy SHA"
        setAccessibilityLabel("Copy SHA")
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side, height: Self.side)
    }

    /// A reused cell's button may still be showing another commit's checkmark; a new SHA
    /// drops it.
    func configure(sha: String) {
        guard sha != self.sha else { return }
        self.sha = sha
        showCopied(false)
    }

    @objc func copySha() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sha, forType: .string)
        showCopied(true)
        onCopy()
    }

    private func showCopied(_ copied: Bool) {
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        image = copied ? Self.copiedImage : Self.copyImage
        guard copied else { return }
        feedbackTimer = Timer.scheduledTimer(withTimeInterval: Self.feedbackDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showCopied(false) }
        }
    }

    private func applyTint() {
        contentTintColor = isOnAccent ? .white : .secondaryLabelColor
    }
}
