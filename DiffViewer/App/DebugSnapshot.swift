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
///   occlusion state, plus the coordinator's routing table, to stdout after the opens,
///   and again on every SIGUSR1 (`kill -USR1 <pid>`) so scripted tab operations can
///   be checked.
/// - `DIFFVIEWER_TAB_STEPS=<JSON array>` runs tab operations after the opens, dumping
///   the windows after each: `next`, `previous`, `detach` (Move Tab to New Window),
///   `merge` (Merge All Windows), `newTab` (the tab bar's "+"), `key:<repo name>`,
///   `open:<path>` (as from Finder), and `shot:<path.png>` (renders the key window).
///   Tab actions are the `NSWindow` actions the Window menu items invoke; `newTab` goes
///   through the responder chain like the "+" button. A step that cannot run (no key
///   window in time, unknown command, unknown window) prints a failure and stops the
///   sequence.
enum DebugLaunchOptions {
    @MainActor private static var applied = false
    @MainActor private static var dumpSignal: (any DispatchSourceProtocol)?

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
        let opens = decodeStringArray(env["DIFFVIEWER_OPEN"])
        let dump = env["DIFFVIEWER_DUMP_WINDOWS"] == "1"
        let selection = env["DIFFVIEWER_SELECT"] ?? ""
        guard !opens.isEmpty || dump || !selection.isEmpty || env["DIFFVIEWER_TAB_STEPS"] != nil else { return }
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
                dumpOnSignal(coordinator)
            }
            let steps = decodeStringArray(env["DIFFVIEWER_TAB_STEPS"])
            if !steps.isEmpty {
                // Activation must come from outside (`osascript -e 'tell application
                // "DiffViewer" to activate'`); a script-launched process cannot make
                // itself active on current macOS.
                for step in steps {
                    guard await eventually({ NSApp.keyWindow != nil }) else {
                        fail(step, "no key window; activate the app first")
                        break
                    }
                    if let failure = await runTabStep(step, services: services) {
                        fail(step, failure)
                        break
                    }
                    try? await Task.sleep(for: .seconds(2))
                    print("### \(step)")
                    dumpWindows(coordinator)
                }
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

    private static func decodeStringArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func fail(_ step: String, _ reason: String) {
        print("### \(step) FAILED: \(reason)")
        fflush(stdout)
    }

    /// Runs one step and returns nil, or a reason it could not run.
    @MainActor
    private static func runTabStep(_ step: String, services: AppServices) async -> String? {
        guard let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow else { return "no key or main window" }
        switch step {
        case "next": targetWindow.selectNextTab(nil)
        case "previous": targetWindow.selectPreviousTab(nil)
        case "detach": targetWindow.moveTabToNewWindow(nil)
        case "merge": targetWindow.mergeAllWindows(nil)
        case "newTab":
            guard NSApp.sendAction(#selector(AppDelegate.newWindowForTab(_:)), to: nil, from: nil) else {
                return "nothing in the responder chain handles newWindowForTab:"
            }
        default:
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return "unknown step" }
            switch parts[0] {
            case "key":
                guard let window = NSApp.windows.first(where: { $0.title == parts[1] }) else { return "no window titled \(parts[1])" }
                window.makeKeyAndOrderFront(nil)
            case "open":
                // Same request `openFromApp` makes, awaited so the next step sees the
                // result; then wait for a created window to register.
                let coordinator = services.coordinator
                let request = WindowCoordinator.OpenRequest(url: URL(fileURLWithPath: parts[1], isDirectory: true), origin: .app)
                await coordinator.open(request)
                guard await eventually({ coordinator.pendingCreates.isEmpty }) else { return "window for \(parts[1]) did not register" }
            case "shot":
                snapshot(targetWindow, to: parts[1])
            default: return "unknown step"
            }
        }
        return nil
    }

    @MainActor
    private static func dumpOnSignal(_ coordinator: WindowCoordinator) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { dumpWindows(coordinator) }
        }
        source.resume()
        dumpSignal = source
    }

    @MainActor
    private static func dumpWindows(_ coordinator: WindowCoordinator) {
        var lines: [String] = ["---"]
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
