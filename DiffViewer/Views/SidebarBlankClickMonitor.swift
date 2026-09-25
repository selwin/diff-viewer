import AppKit
import SwiftUI

/// Calls `onBlankClick` when a plain click lands inside the sidebar list but on no row.
///
/// SwiftUI's sidebar List keeps its selection on such a click and passes no gesture
/// through, so the window's mouse-downs are watched instead. Placed behind the List, this
/// view's frame is the List's, which bounds the clicks it looks at.
struct SidebarBlankClickMonitor: NSViewRepresentable {
    let onBlankClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onBlankClick = onBlankClick
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onBlankClick = onBlankClick
    }

    final class MonitorView: NSView {
        var onBlankClick: () -> Void = {}
        private var monitor: Any?

        override init(frame: NSRect) {
            super.init(frame: frame)
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.inspect(event) }
                return event
            }
        }

        /// The event passes on either way, so the List still takes focus from the click.
        private func inspect(_ event: NSEvent) {
            guard let window, event.window === window,
                // Not the whole device-independent mask: Caps Lock would count as a modifier.
                event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
                bounds.contains(convert(event.locationInWindow, from: nil)),
                let hit = window.contentView?.hitTest(event.locationInWindow),
                let table = sequence(first: hit, next: \.superview).lazy.compactMap(Self.table(at:)).first
            else { return }
            if table.row(at: table.convert(event.locationInWindow, from: nil)) == -1 {
                onBlankClick()
            }
        }

        /// The table itself, or the one a scroll view holds: below a short list the click
        /// can land on the clip view, which is the table's sibling, not its ancestor.
        private static func table(at view: NSView) -> NSTableView? {
            (view as? NSTableView) ?? ((view as? NSScrollView)?.documentView as? NSTableView)
        }
    }
}
