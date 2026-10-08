import AppKit
import SwiftUI

/// Presents the stash picker below the view it backs. An `NSPopover` positioned on the
/// window's content view rather than a SwiftUI popover on the capsule: SwiftUI re-lays out
/// the sidebar's toolbar items on unrelated updates (hover, focus), and AppKit closes a
/// popover whose anchor view moves.
struct StashPickerAnchor: NSViewRepresentable {
    let windowState: WindowState
    let isPresented: Bool

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        // A request made before the capsule had a window is shown once it has one.
        view.onMoveToWindow = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view, coordinator.wantsPopover else { return }
            coordinator.show(below: view)
        }
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.windowState = windowState
        context.coordinator.wantsPopover = isPresented
        if isPresented {
            context.coordinator.show(below: view)
        } else {
            context.coordinator.close()
        }
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.close()
    }

    final class AnchorView: NSView {
        var onMoveToWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMoveToWindow?()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        weak var windowState: WindowState?
        /// Whether the flag asks for the popover, so a request the anchor couldn't serve yet
        /// is kept.
        var wantsPopover = false
        private var popover: NSPopover?

        /// Does nothing while the anchor has no window; it tries again when it gets one.
        func show(below anchor: NSView) {
            guard popover == nil, let windowState, let content = anchor.window?.contentView else { return }
            let host = NSHostingController(rootView: StashPickerPopover().environment(windowState))
            host.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = host
            popover.delegate = self
            self.popover = popover
            popover.show(
                relativeTo: anchor.convert(anchor.bounds, to: content), of: content,
                preferredEdge: content.isFlipped ? .maxY : .minY)
        }

        func close() {
            popover?.close()
        }

        /// A click outside, Esc, or a chosen stash: the flag follows.
        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if windowState?.isStashPickerPresented == true { windowState?.isStashPickerPresented = false }
        }
    }
}
