import AppKit
import SwiftUI

/// Finds the Compare window's `NSWindow`, keeps it out of tab groups and session
/// restoration, and hands it to the coordinator so closing the repository window closes it.
/// It is not entered in `services.windows`, which holds repository and comparison tab windows.
struct CompareWindowAccessor: NSViewRepresentable {
    let owner: WindowID
    let services: AppServices

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.attach = { [owner, services] window in
            window.tabbingMode = .disallowed
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            services.coordinator.registerCompareWindow(window, owner: owner)
        }
        return view
    }

    func updateNSView(_ view: AccessorView, context: Context) {}

    final class AccessorView: NSView {
        var attach: (NSWindow) -> Void = { _ in }

        override init(frame: NSRect) {
            super.init(frame: frame)
            clipsToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach(window) }
        }
    }
}
