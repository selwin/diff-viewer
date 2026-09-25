import AppKit
import SwiftUI

/// Shows a git error, however long it is.
///
/// SwiftUI's `.alert` draws its message as plain text with no height cap, so a failed
/// pre-commit hook's output grew the alert past the screen and left no reachable button.
/// `NSAlert` keeps the summary short and puts the full text in a fixed-size accessory
/// scroll view, where it can be scrolled and selected.
@MainActor
enum ErrorAlert {
    /// A message is long once it runs past this many lines or characters.
    private static let lineLimit = 6
    private static let characterLimit = 500
    /// The most of a long message's first line the summary repeats; the rest scrolls.
    private static let summaryLimit = 160

    /// Splits a message into what the alert says outright and what it scrolls. A short
    /// message is shown whole with no detail; a long one keeps the start of its first
    /// line as the summary and scrolls the whole text. Both are trimmed of surrounding
    /// whitespace, so a hook's trailing newline does not add a blank line.
    static func layout(for message: String) -> (summary: String, detail: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // `isNewline` covers CRLF, which Swift reads as one character.
        let lines = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > lineLimit || trimmed.count > characterLimit else {
            return (trimmed, nil)
        }
        let firstLine = (lines.first.map(String.init) ?? trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = firstLine.count > summaryLimit ? String(firstLine.prefix(summaryLimit)) + "…" : firstLine
        return (summary, trimmed)
    }

    enum Style {
        case generic
        /// Names the failing line up front and always shows the full output, since a
        /// hook's first line is rarely the one that matters.
        case commitFailure
    }

    /// Presents `message` as a sheet on `window` (app-modal when nil) and returns when
    /// the reader dismisses it.
    static func present(_ message: String, in window: NSWindow?, style: Style = .generic) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        var summaryModel: FailureSummaryModel?
        switch style {
        case .generic:
            let (summary, detail) = layout(for: message)
            alert.messageText = "Error"
            alert.informativeText = summary
            if let detail {
                alert.accessoryView = detailView(detail)
            }
        case .commitFailure:
            // The accessory draws the title; see `CommitFailureAccessory`.
            alert.messageText = ""
            alert.informativeText = ""
            let output = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = FailureSummaryModel(output: output, summarizer: FoundationModelsCommitFailureSummarizer())
            summaryModel = model
            let accessory = commitFailureView(output, summary: model)
            alert.accessoryView = accessory
        }
        if let window {
            _ = await alert.beginSheetModal(for: window)
        } else {
            _ = alert.runModal()
        }
        // The hosting view can outlive the alert briefly; nothing may publish once it is gone.
        summaryModel?.cancel()
    }

    /// Sized once from the fonts' real line heights, so larger text still fits; with no
    /// sizing options the hosting view never asks the alert to relayout.
    private static func commitFailureView(
        _ output: String, summary: FailureSummaryModel
    ) -> NSHostingView<CommitFailureAccessory> {
        let summaryView = FailureSummaryView(model: summary, font: .systemFont(ofSize: NSFont.systemFontSize))
        let accessory = CommitFailureAccessory(summary: summaryView, output: output)
        let view = NSHostingView(rootView: accessory)
        view.sizingOptions = []
        view.frame = NSRect(x: 0, y: 0, width: detailSize.width, height: accessory.height)
        return view
    }

    /// The scroller's size in both alerts.
    static let detailSize = NSSize(width: 520, height: 240)

    /// A fixed-size scroller holding the whole message, wrapped and selectable.
    static func detailView(_ detail: String) -> DetailScrollView {
        let scrollView = DetailScrollView(frame: NSRect(origin: .zero, size: detailSize))
        scrollView.clipsToBounds = true
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        let textView = NSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        textView.clipsToBounds = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = detail
        return scrollView
    }
}

/// The alert leaves its accessory scrolled partway down once the sheet is up, so the
/// reset to the first line waits for the view to attach and one more turn of the run
/// loop, after the alert's own layout.
final class DetailScrollView: NSScrollView {
    /// A corner kept clear of text for a button drawn over it. Reapplied on every tile,
    /// since the exclusion is measured from the text container's current width.
    var topTrailingExclusion: NSSize = .zero {
        didSet { tile() }
    }

    override func tile() {
        super.tile()
        let size = topTrailingExclusion
        guard size != .zero, let container = (documentView as? NSTextView)?.textContainer else { return }
        let corner = NSRect(x: container.size.width - size.width, y: 0, width: size.width, height: size.height)
        container.exclusionPaths = [NSBezierPath(rect: corner)]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [self] in
            contentView.scroll(to: .zero)
            reflectScrolledClipView(contentView)
        }
    }
}
