import Foundation

import AppKit

/// Development aids (Debug builds only) so the app can be screenshotted without clicking:
/// - `DIFFVIEWER_SELECT=<changed file id>` selects that sidebar entry after launch
///   (ids look like `unstaged:src/app.swift`).
/// - `DIFFVIEWER_APPEARANCE=dark|light` forces the app appearance.
/// - `DIFFVIEWER_NEXT=<n>` presses Next Change n times once the diff has loaded.
/// - `DIFFVIEWER_FOLD=<up|down|run|all|toggle>[,...]` clicks that control on the first
///   visible separator row (or flips Collapse Unchanged Lines), in order, after the diff
///   has loaded. Clicks go through the real mouse path.
/// - `DIFFVIEWER_SNAPSHOT=<path.png>` renders the window contents to a PNG afterwards
///   (works even when the window is on another Space, unlike `screencapture`).
enum DebugLaunchOptions {
    @MainActor
    static func apply(to appState: AppState) {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        switch env["DIFFVIEWER_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        guard let selection = env["DIFFVIEWER_SELECT"], !selection.isEmpty else { return }
        let nextCount = Int(env["DIFFVIEWER_NEXT"] ?? "") ?? 0
        let folds = (env["DIFFVIEWER_FOLD"] ?? "").split(separator: ",").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            appState.selectedFileID = selection
            if nextCount > 0 {
                try? await Task.sleep(for: .seconds(2))
                for _ in 0..<nextCount { appState.nextChange() }
            }
            if !folds.isEmpty {
                try? await Task.sleep(for: .seconds(nextCount > 0 ? 0.5 : 2))
                for fold in folds {
                    if fold == "toggle" { appState.collapseUnchanged.toggle() } else { clickSeparator(fold) }
                    try? await Task.sleep(for: .seconds(0.2))
                }
            }
            if let path = env["DIFFVIEWER_SNAPSHOT"], !path.isEmpty {
                try? await Task.sleep(for: .seconds(nextCount > 0 || !folds.isEmpty ? 1 : 3))
                snapshot(to: path)
            }
        }
        #endif
    }

    @MainActor
    private static func clickSeparator(_ control: String) {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }),
              let container = window.contentView?.descendant(SideBySideContainerView.self) else { return }
        let pane = container.rightPane
        let wanted: FoldControl? = switch control {
        case "up": .expandUp
        case "down": .expandDown
        case "run": .expandRun
        default: nil
        }
        let visible = container.visibleDisplayRange
        for index in visible {
            guard case let .separator(hidden) = pane.displayRows[index] else { continue }
            let rowRect = NSRect(x: pane.visibleRect.minX, y: pane.layout.y(forRow: index), width: pane.visibleRect.width, height: pane.layout.rowHeight)
            let rects = pane.controlRects(for: hidden, rowRect: rowRect)
            let point: NSPoint
            if let wanted, let hit = rects.first(where: { $0.control == wanted }) {
                point = NSPoint(x: hit.rect.midX, y: hit.rect.midY)
            } else {
                point = NSPoint(x: rowRect.minX + 300, y: rowRect.midY)
            }
            let windowPoint = pane.convert(point, to: nil)
            let flags: NSEvent.ModifierFlags = control == "all" ? [.option] : []
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            pane.mouseDown(with: event)
            return
        }
    }

    @MainActor
    private static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

private extension NSView {
    func descendant<T: NSView>(_ type: T.Type) -> T? {
        if let match = self as? T { return match }
        for child in subviews { if let match = child.descendant(type) { return match } }
        return nil
    }
}
