import AppKit

extension DebugLaunchOptions {
    /// Applies `DIFFVIEWER_WINDOW_SIZE`, `DIFFVIEWER_SIDEBAR_SCROLL` and
    /// `DIFFVIEWER_FOCUS_LIST`, in that order.
    @MainActor
    static func arrangeSidebar(env: [String: String], window: NSWindow) async {
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
