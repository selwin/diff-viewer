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
/// - `DIFFVIEWER_OPEN=<JSON array of paths>` opens those repositories, in order, as if
///   from Finder, after the initial window is up.
/// - `DIFFVIEWER_DUMP_WINDOWS=1` prints each window's title, tab-group size, key and
///   occlusion state, plus the coordinator's routing table, to stdout after the opens.
enum DebugLaunchOptions {
    @MainActor private static var applied = false

    /// Targets the key window's state, or the first populated window when the app
    /// is not active (as when launched from a script). Runs once per launch.
    @MainActor
    static func apply(to services: AppServices) {
        #if DEBUG
        guard !applied else { return }
        applied = true
        let env = ProcessInfo.processInfo.environment
        switch env["DIFFVIEWER_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let opens = decodePaths(env["DIFFVIEWER_OPEN"])
        let dump = env["DIFFVIEWER_DUMP_WINDOWS"] == "1"
        let selection = env["DIFFVIEWER_SELECT"] ?? ""
        guard !opens.isEmpty || dump || !selection.isEmpty else { return }
        let nextCount = Int(env["DIFFVIEWER_NEXT"] ?? "") ?? 0
        let folds = (env["DIFFVIEWER_FOLD"] ?? "").split(separator: ",").map(String.init)
        // One ordered sequence: opens finish before the target window is chosen, so the
        // selection, folding, and snapshot all act on the same window.
        Task { @MainActor in
            let coordinator = services.coordinator
            for path in opens {
                let request = WindowCoordinator.OpenRequest(url: URL(fileURLWithPath: path, isDirectory: true), origin: .app)
                await coordinator.open(request)
                try? await Task.sleep(for: .seconds(1))
            }
            if dump {
                try? await Task.sleep(for: .seconds(2))
                dumpWindows(coordinator)
            }
            guard !selection.isEmpty else { return }
            @MainActor func target() -> WindowState? {
                let key = coordinator.keyWindowState
                return key?.isEmpty == false ? key : coordinator.windows.values.first { !$0.isEmpty }
            }
            _ = await eventually { target() != nil }
            try? await Task.sleep(for: .seconds(0.5))
            guard let windowState = target(), let window = services.windows[windowState.id] else { return }
            // The snapshot renders offscreen, so lift the visibility gate for this window.
            windowState.isVisible = true
            windowState.selectedFileID = selection
            if nextCount > 0 {
                try? await Task.sleep(for: .seconds(2))
                for _ in 0..<nextCount { windowState.nextChange() }
            }
            if !folds.isEmpty {
                try? await Task.sleep(for: .seconds(nextCount > 0 ? 0.5 : 2))
                for fold in folds {
                    if fold == "toggle" { services.preferences.collapseUnchanged.toggle() } else { clickSeparator(fold, in: window) }
                    try? await Task.sleep(for: .seconds(0.2))
                }
            }
            if let path = env["DIFFVIEWER_SNAPSHOT"], !path.isEmpty {
                try? await Task.sleep(for: .seconds(nextCount > 0 || !folds.isEmpty ? 1 : 3))
                snapshot(window, to: path)
            }
        }
        #endif
    }

    private static func decodePaths(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    @MainActor
    private static func dumpWindows(_ coordinator: WindowCoordinator) {
        var lines: [String] = []
        for window in NSApp.windows where window.contentView != nil {
            let group = window.tabGroup?.windows.count ?? 1
            let visible = window.occlusionState.contains(.visible)
            lines.append("window title=\(window.title) tabGroup=\(group) key=\(window.isKeyWindow) visible=\(visible)")
        }
        let states = coordinator.windows.values.map { state in
            "state repo=\(state.repoName) key=\(state.isKey) visible=\(state.isVisible) files=\(state.files.count) stale=\(state.diffStale)"
        }
        lines.append(contentsOf: states.sorted())
        lines.append("openOrder=\(coordinator.openOrder.map(\.name)) rootIndex=\(coordinator.rootIndex.keys.map(\.name).sorted()) pending=\(coordinator.pendingCreates.count) lastActive=\(coordinator.lastActiveRepositoryRoot?.name ?? "nil")")
        print(lines.joined(separator: "\n"))
        fflush(stdout)
    }

    @MainActor
    private static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @MainActor
    private static func clickSeparator(_ control: String, in window: NSWindow) {
        guard let container = window.contentView?.descendant(SideBySideContainerView.self) else { return }
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
    private static func snapshot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
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
