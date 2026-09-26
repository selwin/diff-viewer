import AppKit
import Foundation

/// Development aids (Debug builds only) so the app can be screenshotted without clicking:
/// - `DIFFVIEWER_DEFAULTS_SUITE=<domain>` keeps preferences and the saved session in that
///   `UserDefaults` suite, so scripted runs leave an Xcode-run instance's state alone.
/// - `DIFFVIEWER_SELECT=<changed file id>[,...]` selects those sidebar entries after launch
///   (ids look like `unstaged:src/app.swift`, or `commit:<sha>:src/app.swift`);
///   `all` selects All changes.
/// - `DIFFVIEWER_WINDOW_SIZE=<w>x<h>` resizes the window's content, then
///   `DIFFVIEWER_SIDEBAR_SCROLL=<points>|bottom` scrolls the file list, and
///   `DIFFVIEWER_FOCUS_LIST=1` makes it first responder, all after the selection, so the
///   selection popover can be screenshotted.
/// - `DIFFVIEWER_SCOPE=<sha>` points the commit picker at that commit (a prefix is
///   enough) once its history has loaded, before `DIFFVIEWER_SELECT` is applied, so a
///   commit's sidebar and diffs can be screenshotted.
/// - `DIFFVIEWER_COMMIT_SHEET=1` opens the commit sheet after the selection is applied;
///   `DIFFVIEWER_SNAPSHOT` then renders the sheet instead of the window.
/// - `DIFFVIEWER_STAGING_TRAY=expanded|collapsed` sets the window repository's staging
///   tray that way, alongside the commit sheet, and keeps it for later runs in the suite.
/// - `DIFFVIEWER_COMMIT_PICKER=1` opens the commit picker popover the same way;
///   `DIFFVIEWER_SNAPSHOT` then renders the popover's window.
/// - `DIFFVIEWER_BRANCH_PICKER=1` opens the branch picker popover, rendered the same way.
/// - `DIFFVIEWER_KEYS=<step>[,...]` drives the key window after the sheets open: a key
///   code (`126` is ↑, `36` Return, `53` Escape), a character (reaches type-select),
///   `click:<x>x<y>` / `dblclick:<x>x<y>` in top-left content coordinates,
///   `winclick:<x>x<y>` (the same click in the target window itself, which closes a
///   popover from outside), or `picker` to toggle the commit picker. It needs no
///   `DIFFVIEWER_SELECT`, so clicks can make the selection. An inactive app's window
///   never really becomes key, so clicks take the first-mouse path: one on a view that
///   refuses first mouse (such as the diff pane) is dropped.
/// - `DIFFVIEWER_APPEARANCE=dark|light` forces the app appearance.
/// - `DIFFVIEWER_NEXT=<n>` presses Next Change n times once the diff has loaded.
/// - `DIFFVIEWER_FIND=<query>` opens the find bar with that query after the Next Change
///   presses, and waits for its search to finish before the steps below.
/// - `DIFFVIEWER_FOLD=<up|down|run|all|toggle>[,...]` clicks that control on the first
///   visible separator row (or flips Collapse Unchanged Lines), in order, after the diff
///   has loaded. Clicks go through the real mouse path.
/// - `DIFFVIEWER_SCROLL_X=<points>[,...]` scrolls the panes horizontally to each offset
///   in turn after the diff has loaded, through the clip view like a scroller does, so
///   partial redraws on horizontal scroll can be screenshotted with `screencapture`.
/// - `DIFFVIEWER_SNAPSHOT=<path.png>` renders the window contents to a PNG afterwards
///   (works even when the window is on another Space, unlike `screencapture`).
/// - `DIFFVIEWER_OPEN=<JSON array of paths>` opens those repositories, in order, as if
///   from Finder, once the saved session has finished restoring.
/// - `DIFFVIEWER_DUMP_WINDOWS=1` prints each window's title, tab-group size, key and
///   occlusion state, plus the coordinator's routing table, phase, the saved session,
///   and the prefetch-worker and difft-process peaks, to stdout after the opens, and
///   again on every SIGUSR1 (`kill -USR1 <pid>`) so scripted tab operations can be
///   checked.
/// - `DIFFVIEWER_TAB_STEPS=<JSON array>` runs tab operations after the opens, dumping
///   the windows after each: `next`, `previous`, `detach` (Move Tab to New Window),
///   `merge` (Merge All Windows), `newTab` (the tab bar's "+"), `key:<repo name>`,
///   `open:<path>` (as from Finder), `shot:<path.png>` (renders the key window),
///   `measure:<changed file id>` (selects that file in the key window and prints the
///   selection-to-content latency with the difft cache stats delta, so a hit and a miss
///   can be told apart; the file must not be selected already), `sleep:<seconds>`, and
///   `quit` (Cmd+Q, through the delegate, so
///   the session snapshot is written). Tab actions are the `NSWindow` actions the
///   Window menu items invoke; `newTab` goes through the responder chain like the "+"
///   button. A step that cannot run (no key window in time, unknown command, unknown
///   window) prints a failure and stops the sequence.
enum DebugLaunchOptions {
    /// The store the app runs on: `DIFFVIEWER_DEFAULTS_SUITE` in a Debug build, else standard.
    static var defaults: UserDefaults {
        #if DEBUG
            if let suite = ProcessInfo.processInfo.environment["DIFFVIEWER_DEFAULTS_SUITE"], !suite.isEmpty,
                let suiteDefaults = UserDefaults(suiteName: suite)
            {
                return suiteDefaults
            }
        #endif
        return .standard
    }

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
            let scopeSha = env["DIFFVIEWER_SCOPE"] ?? ""
            let commitSheet = env["DIFFVIEWER_COMMIT_SHEET"] == "1"
            let commitPicker = env["DIFFVIEWER_COMMIT_PICKER"] == "1"
            let branchPicker = env["DIFFVIEWER_BRANCH_PICKER"] == "1"
            let findQuery = env["DIFFVIEWER_FIND"] ?? ""
            // Any other value is ignored, so a typo never clears the saved state.
            let trayExpansion = ["expanded": true, "collapsed": false][env["DIFFVIEWER_STAGING_TRAY"] ?? ""]
            let needsWindow =
                !selection.isEmpty || !scopeSha.isEmpty || commitSheet || commitPicker || branchPicker
                || !findQuery.isEmpty || !(env["DIFFVIEWER_KEYS"] ?? "").isEmpty
                || env["DIFFVIEWER_FOCUS_LIST"] == "1" || trayExpansion != nil
            guard !opens.isEmpty || dump || needsWindow || env["DIFFVIEWER_TAB_STEPS"] != nil else { return }
            let nextCount = Int(env["DIFFVIEWER_NEXT"] ?? "") ?? 0
            // One ordered sequence: opens finish before the target window is chosen, so the
            // selection, folding, and snapshot all act on the same window.
            Task { @MainActor in
                let coordinator = services.coordinator
                // Opens during restoration would race the saved repositories for the
                // initial window; wait for the batch to settle first.
                _ = await eventually(attempts: 300) { coordinator.phase == .running }
                for path in opens {
                    let request = WindowCoordinator.OpenRequest(
                        url: URL(fileURLWithPath: path, isDirectory: true), origin: .app)
                    await coordinator.open(request)
                    try? await Task.sleep(for: .seconds(1))
                }
                if dump {
                    try? await Task.sleep(for: .seconds(2))
                    dumpWindows(services)
                    dumpOnSignal(services)
                }
                let steps = decodeStringArray(env["DIFFVIEWER_TAB_STEPS"])
                if !steps.isEmpty {
                    // Activation must come from outside (`osascript -e 'tell application
                    // "DiffViewer" to activate'`); a script-launched process cannot make
                    // itself active on current macOS.
                    for step in steps {
                        let needsKeyWindow = step != "quit" && !step.hasPrefix("sleep:")
                        let hasKeyWindow = needsKeyWindow ? await eventually({ NSApp.keyWindow != nil }) : true
                        guard hasKeyWindow else {
                            fail(step, "no key window; activate the app first")
                            break
                        }
                        if let failure = await runTabStep(step, services: services) {
                            fail(step, failure)
                            break
                        }
                        try? await Task.sleep(for: .seconds(2))
                        print("### \(step)")
                        dumpWindows(services)
                    }
                }
                guard needsWindow else { return }
                _ = await eventually { targetState(coordinator) != nil }
                try? await Task.sleep(for: .seconds(0.5))
                guard let windowState = targetState(coordinator), let window = services.windows[windowState.id]
                else { return }
                // The snapshot renders offscreen, so lift the visibility gate for this window.
                windowState.isVisible = true
                if !scopeSha.isEmpty {
                    await selectScope(scopeSha, in: windowState)
                }
                if !selection.isEmpty {
                    windowState.selection =
                        selection == "all"
                        ? [.allChanges] : Set(selection.split(separator: ",").map { .file(String($0)) })
                }
                await arrangeSidebar(env: env, window: window)
                if let root = windowState.repositoryRoot, let trayExpansion {
                    windowState.preferences.setStagingTrayExpanded(trayExpansion, for: root)
                }
                windowState.isCommitSheetPresented = commitSheet
                windowState.isCommitPickerPresented = commitPicker
                windowState.isBranchPickerPresented = branchPicker
                let keys = (env["DIFFVIEWER_KEYS"] ?? "").split(separator: ",").map(String.init)
                if !keys.isEmpty {
                    try? await Task.sleep(for: .seconds(1))
                    await sendKeys(keys, in: windowState, window: window)
                }
                if nextCount > 0 {
                    try? await Task.sleep(for: .seconds(2))
                    for _ in 0..<nextCount { windowState.nextChange() }
                }
                await finishSequence(
                    env: env, afterNext: nextCount > 0, windowState: windowState, window: window,
                    services: services)
            }
        #endif
    }

    /// The window the debug hooks act on: the key one, or the first populated one when
    /// the app is not active.
    @MainActor
    private static func targetState(_ coordinator: WindowCoordinator) -> WindowState? {
        let key = coordinator.keyWindowState
        return key?.isEmpty == false ? key : coordinator.windows.values.first { !$0.isEmpty }
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
        if step == "quit" {
            NSApp.terminate(nil)
            return nil
        }
        if step.hasPrefix("sleep:") {
            try? await Task.sleep(for: .seconds(Double(step.dropFirst("sleep:".count)) ?? 1))
            return nil
        }
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
                guard let window = NSApp.windows.first(where: { $0.title == parts[1] }) else {
                    return "no window titled \(parts[1])"
                }
                window.makeKeyAndOrderFront(nil)
            case "open":
                // Same request `openFromApp` makes, awaited so the next step sees the
                // result; then wait for a created window to register.
                let coordinator = services.coordinator
                let request = WindowCoordinator.OpenRequest(
                    url: URL(fileURLWithPath: parts[1], isDirectory: true), origin: .app)
                await coordinator.open(request)
                guard await eventually({ coordinator.pendingCreates.isEmpty }) else {
                    return "window for \(parts[1]) did not register"
                }
            case "shot":
                snapshot(targetWindow, to: parts[1])
            case "measure":
                return await measureSelection(parts[1], services: services)
            default: return "unknown step"
            }
        }
        return nil
    }

    /// Selects `fileID` in the key window and reports how long the diff took to
    /// appear, with the cache stats delta (a miss launches a process; a hit does not).
    /// The stats are app-wide, so prefetch activity in the same interval shows up in
    /// the delta too; read `misses`/`launches` as "at least the measured file".
    @MainActor
    private static func measureSelection(_ fileID: String, services: AppServices) async -> String? {
        guard let state = services.coordinator.keyWindowState, !state.isEmpty else { return "the key window is empty" }
        guard state.files.contains(where: { $0.id == fileID }) else {
            return "no changed file \(fileID) in \(state.repoName)"
        }
        guard state.selectedFileID != fileID else { return "\(fileID) is already selected; nothing would load" }
        let before = await services.cache.stats
        let start = ContinuousClock.now
        state.selection = [.file(fileID)]
        // Poll finely: a cache hit publishes in well under the dump loop's 100 ms tick.
        guard
            await eventually(
                attempts: 12000, every: .milliseconds(5),
                {
                    state.diffLoader.contentFileID == fileID && state.diffLoader.content != nil
                        && !state.diffLoader.isLoading
                })
        else {
            return "no content for \(fileID) within 60 s"
        }
        let elapsed = ContinuousClock.now - start
        let after = await services.cache.stats
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print(
            String(
                format: "measure %@ content=%.0fms hits=+%d misses=+%d joins=+%d launches=+%d",
                fileID, ms, after.hits - before.hits, after.misses - before.misses,
                after.inFlightJoins - before.inFlightJoins, after.launches - before.launches))
        fflush(stdout)
        return nil
    }

    @MainActor
    private static func dumpOnSignal(_ services: AppServices) {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { dumpWindows(services) }
        }
        source.resume()
        dumpSignal = source
    }

    @MainActor
    private static func dumpWindows(_ services: AppServices) {
        let coordinator = services.coordinator
        var lines: [String] = ["---"]
        var seenGroups: [NSWindowTabGroup] = []
        for window in NSApp.windows where window.contentView != nil {
            let group = window.tabGroup?.windows.count ?? 1
            let visible = window.occlusionState.contains(.visible)
            lines.append("window title=\(window.title) tabGroup=\(group) key=\(window.isKeyWindow) visible=\(visible)")
            if let tabGroup = window.tabGroup, !seenGroups.contains(where: { $0 === tabGroup }) {
                seenGroups.append(tabGroup)
                lines.append("tabs=\(tabGroup.windows.map(\.title))")
            }
        }
        let states = coordinator.windows.values.map { state in
            "state repo=\(state.repoName) key=\(state.isKey) visible=\(state.isVisible) "
                + "files=\(state.files.count) stale=\(state.diffStale) "
                + "scope=\(state.scopeDisplayTitle) picker=\(state.isCommitPickerPresented) "
                + "branchPicker=\(state.isBranchPickerPresented)"
        }
        lines.append(contentsOf: states.sorted())
        lines.append(
            "openOrder=\(coordinator.openOrder.map(\.name)) "
                + "rootIndex=\(coordinator.rootIndex.keys.map(\.name).sorted()) "
                + "pending=\(coordinator.pendingCreates.count) "
                + "lastActive=\(coordinator.lastActiveRepositoryRoot?.name ?? "nil") "
                + "phase=\(coordinator.phase)"
        )
        let defaults = Self.defaults
        let saved = (defaults.stringArray(forKey: WindowCoordinator.SessionKeys.openRoots) ?? []).map {
            RepositoryRoot(path: $0).name
        }
        let savedActive =
            defaults.string(forKey: WindowCoordinator.SessionKeys.lastActive).map { RepositoryRoot(path: $0).name }
            ?? "nil"
        lines.append("saved=\(saved) savedActive=\(savedActive)")
        let gauge = DifftRunner.processGauge
        lines.append(
            "prefetchWorkersPeak=\(services.prefetcher.peakActiveWorkers) "
                + "difftRunning=\(gauge.running) difftPeak=\(gauge.peak)"
        )
        print(lines.joined(separator: "\n"))
        fflush(stdout)
    }

    /// Points the commit picker at `sha` (a prefix is enough) once the history that
    /// contains it has loaded, then gives the commit's file list a moment to arrive.
    @MainActor
    private static func selectScope(_ sha: String, in windowState: WindowState) async {
        _ = await eventually(attempts: 100) { windowState.history.commits.contains { $0.ref.sha.hasPrefix(sha) } }
        guard let commit = windowState.history.commits.first(where: { $0.ref.sha.hasPrefix(sha) }) else {
            print("### DIFFVIEWER_SCOPE: no commit matching \(sha) in the loaded history")
            return
        }
        windowState.select(commit: commit)
        try? await Task.sleep(for: .seconds(1))
    }

    /// Types `keys` into whichever window is key as each is sent, so a Return that
    /// closes a sheet or popover hands the rest to the window beneath. `picker` and
    /// `winclick` act on the target window, which is not key while the popover is.
    @MainActor
    private static func sendKeys(_ keys: [String], in windowState: WindowState, window target: NSWindow) async {
        if await !eventually({ NSApp.keyWindow != nil }) {
            // Activation can be refused while another app is in use; an inactive app has
            // no key window, so make the picker's (or the target) key by hand.
            print("### DIFFVIEWER_KEYS: no key window; making one key without activation")
            (pickerWindow(of: target) ?? target).makeKey()
        }
        for key in keys {
            if key == "picker" {
                windowState.isCommitPickerPresented.toggle()
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let window = NSApp.keyWindow ?? pickerWindow(of: target) ?? target
            if let mouse = key.split(separator: ":").first, ["click", "dblclick", "winclick"].contains(mouse) {
                let kind = mouse == "winclick" ? "click" : String(mouse)
                postMouse(kind, key.dropFirst(mouse.count + 1), in: mouse == "winclick" ? target : window)
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            let code = UInt16(key)
            // Escape carries its character, or it never reaches `cancelOperation:`.
            let characters = code == nil ? key : (code == 53 ? "\u{1b}" : "")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard
                    let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code ?? 0)
                else { continue }
                window.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Posts a click or double-click at `<x>x<y>` (top-left content coordinates) through
    /// the event queue, so table tracking loops see the mouse-up.
    @MainActor
    private static func postMouse(_ kind: String, _ spec: Substring, in window: NSWindow) {
        let parts = spec.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, let content = window.contentView else { return }
        let point = NSPoint(x: parts[0], y: content.bounds.height - parts[1])
        func post(_ type: NSEvent.EventType, clickCount: Int) {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                    pressure: 1)
            else { return }
            NSApp.postEvent(event, atStart: false)
        }
        for count in 1...(kind == "dblclick" ? 2 : 1) {
            post(.leftMouseDown, clickCount: count)
            post(.leftMouseUp, clickCount: count)
        }
    }

    @MainActor
    private static func eventually(
        attempts: Int = 50, every interval: Duration = .milliseconds(100), _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: interval)
        }
        return condition()
    }

    /// Scrolls the right pane's clip view to each x in turn; the container syncs the left pane.
    @MainActor
    private static func scrollHorizontally(to xs: [Double], in window: NSWindow) async {
        guard let container = window.contentView?.descendant(SideBySideContainerView.self),
            let scroll = container.rightPane.enclosingScrollView
        else { return }
        let clip = scroll.contentView
        for x in xs {
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
            scroll.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .seconds(0.3))
        }
    }

    @MainActor
    private static func clickSeparator(_ control: String, in window: NSWindow) {
        guard let container = window.contentView?.descendant(SideBySideContainerView.self) else { return }
        let pane = container.rightPane
        let wanted: FoldControl? =
            switch control {
            case "up": .expandUp
            case "down": .expandDown
            case "run": .expandRun
            default: nil
            }
        let visible = container.visibleDisplayRange
        for index in visible {
            guard case let .separator(hidden) = pane.displayRows[index] else { continue }
            let rowRect = NSRect(
                x: pane.visibleRect.minX, y: pane.layout.y(forRow: index), width: pane.visibleRect.width,
                height: pane.layout.rowHeight)
            let rects = pane.controlRects(for: hidden, rowRect: rowRect)
            let point: NSPoint
            if let wanted, let hit = rects.first(where: { $0.control == wanted }) {
                point = NSPoint(x: hit.rect.midX, y: hit.rect.midY)
            } else {
                point = NSPoint(x: rowRect.minX + 300, y: rowRect.midY)
            }
            let windowPoint = pane.convert(point, to: nil)
            let flags: NSEvent.ModifierFlags = control == "all" ? [.option] : []
            guard
                let event = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: windowPoint, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { return }
            pane.mouseDown(with: event)
            return
        }
    }

    /// A picker popover's window while it is up: a child of `window` hosting either
    /// picker's container.
    @MainActor
    private static func pickerWindow(of window: NSWindow) -> NSWindow? {
        let candidates = (window.childWindows ?? []) + NSApp.windows
        return candidates.first { candidate in
            guard candidate.isVisible, let content = candidate.contentView else { return false }
            return content.descendant(CommitPickerContainerView.self) != nil
                || content.descendant(BranchPickerContainerView.self) != nil
        }
    }

    @MainActor
    private static func snapshot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

extension DebugLaunchOptions {
    /// The steps after the selection and Next Change presses: find, folds, horizontal
    /// scrolls, then the snapshot. A failed find exits first, so no snapshot is written.
    @MainActor
    fileprivate static func finishSequence(
        env: [String: String], afterNext: Bool, windowState: WindowState, window: NSWindow,
        services: AppServices
    ) async {
        let folds = (env["DIFFVIEWER_FOLD"] ?? "").split(separator: ",").map(String.init)
        let scrollXs = (env["DIFFVIEWER_SCROLL_X"] ?? "").split(separator: ",").compactMap { Double($0) }
        if let query = env["DIFFVIEWER_FIND"], !query.isEmpty {
            if let failure = await openFind(query, in: windowState) {
                fputs("### DIFFVIEWER_FIND FAILED: \(failure)\n", stderr)
                exit(1)
            }
        }
        if !folds.isEmpty {
            try? await Task.sleep(for: .seconds(afterNext ? 0.5 : 2))
            for fold in folds {
                if fold == "toggle" {
                    services.preferences.collapseUnchanged.toggle()
                } else {
                    clickSeparator(fold, in: window)
                }
                try? await Task.sleep(for: .seconds(0.2))
            }
        }
        if !scrollXs.isEmpty {
            try? await Task.sleep(for: .seconds(afterNext || !folds.isEmpty ? 0.5 : 2))
            await scrollHorizontally(to: scrollXs, in: window)
        }
        if let path = env["DIFFVIEWER_SNAPSHOT"], !path.isEmpty {
            try? await Task.sleep(for: .seconds(afterNext || !folds.isEmpty || !scrollXs.isEmpty ? 1 : 3))
            snapshot(pickerWindow(of: window) ?? window.attachedSheet ?? window, to: path)
        }
    }

    /// Opens the find bar on `query` and waits for its search to finish (no match counts),
    /// then 100 ms for the panes to draw it. Returns nil, or why it could not.
    @MainActor
    private static func openFind(_ query: String, in windowState: WindowState) async -> String? {
        guard await eventually(attempts: 100, { windowState.isFindAvailable }) else {
            return "nothing searchable on screen"
        }
        windowState.showFindBar()
        windowState.find.query = query
        let finished = await eventually(attempts: 100) {
            windowState.find.isCurrent && windowState.find.results?.key.query == query
        }
        guard finished else { return "search for \(query) did not finish" }
        try? await Task.sleep(for: .milliseconds(100))
        return nil
    }
}

extension DebugLaunchOptions {
    /// Applies `DIFFVIEWER_WINDOW_SIZE`, `DIFFVIEWER_SIDEBAR_SCROLL` and
    /// `DIFFVIEWER_FOCUS_LIST`, in that order.
    @MainActor
    fileprivate static func arrangeSidebar(env: [String: String], window: NSWindow) async {
        let size = (env["DIFFVIEWER_WINDOW_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
        let scroll = env["DIFFVIEWER_SIDEBAR_SCROLL"] ?? ""
        let focus = env["DIFFVIEWER_FOCUS_LIST"] == "1"
        guard size.count == 2 || !scroll.isEmpty || focus else { return }
        try? await Task.sleep(for: .seconds(1))
        if size.count == 2 {
            window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        // The Changes list is the window's first table, ahead of the staging tray's.
        guard let table = window.contentView?.descendant(NSTableView.self) else {
            print("### DIFFVIEWER_SIDEBAR: no file list found")
            return
        }
        if !scroll.isEmpty, let clip = table.enclosingScrollView?.contentView {
            let bottom = table.frame.height - clip.bounds.height + clip.contentInsets.bottom
            let y = scroll == "bottom" ? bottom : (Double(scroll) ?? 0) - clip.contentInsets.top
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        if focus {
            window.makeFirstResponder(table)
        }
        try? await Task.sleep(for: .seconds(0.5))
    }
}

extension NSView {
    fileprivate func descendant<T: NSView>(_ type: T.Type) -> T? {
        if let match = self as? T { return match }
        for child in subviews { if let match = child.descendant(type) { return match } }
        return nil
    }
}
