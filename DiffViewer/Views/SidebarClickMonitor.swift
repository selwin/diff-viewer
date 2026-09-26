import AppKit
import SwiftUI

/// Watches clicks inside the sidebar list: any click makes the list first responder, and a
/// plain click on no row calls `onBlankClick`.
///
/// Clicking a row of SwiftUI's sidebar List does not take first responder back from an
/// AppKit view such as the diff pane, so the selection would stay grey and the popover and
/// the Changes menu would stay off. The List also keeps its selection on a click below the
/// last row and passes no gesture through, so the window's mouse-downs are watched instead.
/// Placed behind the List, this view's frame is the List's, which bounds the clicks it
/// looks at.
struct SidebarClickMonitor: NSViewRepresentable {
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

        /// The event passes on either way, so the List still handles the click.
        private func inspect(_ event: NSEvent) {
            guard let window, event.window === window,
                bounds.contains(convert(event.locationInWindow, from: nil)),
                let hit = window.contentView?.hitTest(event.locationInWindow),
                let table = sequence(first: hit, next: \.superview).lazy.compactMap(Self.table(at:)).first
            else { return }
            if window.firstResponder !== table {
                window.makeFirstResponder(table)
            }
            // Not the whole device-independent mask: Caps Lock would count as a modifier.
            guard event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]) else { return }
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
