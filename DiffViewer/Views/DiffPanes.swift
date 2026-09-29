import SwiftUI

/// The side-by-side panes wired to the window's find, navigation and preferences, shared
/// by the single-file and All changes detail views.
struct DiffPanes: View {
    @Environment(WindowState.self) private var windowState
    @Environment(Preferences.self) private var preferences
    let content: PaneContent
    var isHidden = false
    var onTopVisibleSectionChange: ((VisibleSectionReference?) -> Void)?

    var body: some View {
        SideBySideView(
            content: content,
            styles: windowState.diffLoader.styles,
            fontSize: preferences.fontSize,
            scrollTarget: windowState.scrollTarget,
            currentBlock: windowState.currentChangeIndex,
            collapseUnchanged: preferences.collapseUnchanged,
            foldOptions: preferences.foldOptions,
            isHidden: isHidden,
            onTopVisibleSectionChange: onTopVisibleSectionChange,
            findScope: windowState.paneFindScope,
            findPresentation: windowState.find.presentation,
            findReveal: windowState.find.activeReveal,
            paneFocusRequest: windowState.find.paneFocusRequest,
            onDisplayedDocumentChange: { windowState.reportDisplayed($0) },
            onPaneInteraction: { _ in windowState.find.notePaneInteraction() },
            onVisibleRowsChange: { windowState.find.noteVisibleRows($0, contentID: $1) },
            onPaneFocusApplied: { windowState.find.acknowledgePaneFocus(id: $0) }
        )
    }
}
