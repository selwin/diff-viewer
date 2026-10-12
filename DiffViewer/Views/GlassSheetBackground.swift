import AppKit
import SwiftUI

extension View {
    /// Liquid Glass behind a sheet's content, so the diff underneath shows through. macOS 26
    /// sheets paint an opaque fill that no `presentationBackground` covers, so the sheet's
    /// window is cleared first; if that ever fails the sheet just stays opaque.
    func glassSheetBackground() -> some View {
        glassEffect(.regular, in: ConcentricRectangle())
            .presentationBackground { SheetWindowClearer() }
    }
}

/// Makes the sheet's window transparent and hides the system's sheet material, which is a
/// solid fill rather than a blur, so the glass can see the parent window.
private struct SheetWindowClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> ClearingView { ClearingView() }
    func updateNSView(_ view: ClearingView, context: Context) {}

    final class ClearingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            // The material view is a direct child of the theme frame (the content view's superview).
            for case let material as NSVisualEffectView in window.contentView?.superview?.subviews ?? [] {
                material.isHidden = true
            }
        }
    }
}
