import SwiftUI

/// Header plus side-by-side panes for the selected file.
struct DiffDetailView: View {
    @Environment(WindowState.self) private var windowState
    @Environment(Preferences.self) private var preferences
    let file: ChangedFile
    /// Set when navigation asks for a change while the preview covers the source; it drops
    /// back to source for this file only, without touching the persisted preference.
    @State private var sourceRevealedByNavigation = false

    var body: some View {
        let loader = windowState.diffLoader
        VStack(spacing: 0) {
            header(loader: loader)
            Divider()
            if windowState.find.isPresented, windowState.isFindAvailable {
                FindBarView(find: windowState.find)
                Divider()
            }
            content(loader: loader)
        }
        // The parent keys this view by file id, so the override resets with the selection.
        .onChange(of: windowState.scrollTarget?.id) { _, newValue in
            if newValue != nil, showsPreview(loader: loader) { sourceRevealedByNavigation = true }
        }
        // A find reveal lands in the source, so it drops the preview the same way.
        .onChange(of: windowState.find.activeReveal?.id) { _, newValue in
            if newValue != nil, showsPreview(loader: loader) { sourceRevealedByNavigation = true }
        }
    }

    /// True when the rendered preview should cover the source for this selection.
    private func showsPreview(loader: DiffLoader) -> Bool {
        guard case .text? = loader.content, loader.imagePreview != nil else { return false }
        return preferences.showsSVGPreview && !sourceRevealedByNavigation
    }

    /// Nil unless there is something to toggle between. The setter writes the preference,
    /// so an explicit choice also ends a navigation-driven reveal.
    private func previewBinding(loader: DiffLoader) -> Binding<Bool>? {
        guard case .text? = loader.content, loader.imagePreview != nil else { return nil }
        return Binding(
            get: { preferences.showsSVGPreview && !sourceRevealedByNavigation },
            set: { newValue in
                preferences.showsSVGPreview = newValue
                sourceRevealedByNavigation = false
            })
    }

    private func header(loader: DiffLoader) -> some View {
        FileHeaderView(
            file: file, stats: file.lineStats, isLoading: loader.isLoading,
            showsPreview: previewBinding(loader: loader))
    }

    @ViewBuilder
    private func content(loader: DiffLoader) -> some View {
        if let message = loader.errorMessage {
            ContentUnavailableView(
                "Couldn't load diff", systemImage: "exclamationmark.triangle", description: Text(message))
        } else {
            switch loader.content {
            case let .text(document)?:
                let previewing = showsPreview(loader: loader)
                // The source view stays in the hierarchy so folds, scroll position and
                // selection survive a trip through the preview.
                ZStack {
                    SideBySideView(
                        content: .file(document),
                        styles: loader.styles,
                        fontSize: preferences.fontSize,
                        scrollTarget: windowState.scrollTarget,
                        currentBlock: windowState.currentChangeIndex,
                        collapseUnchanged: preferences.collapseUnchanged,
                        foldOptions: preferences.foldOptions,
                        isHidden: previewing,
                        findScope: windowState.paneFindScope,
                        findPresentation: windowState.find.presentation,
                        findReveal: windowState.find.activeReveal,
                        paneFocusRequest: windowState.find.paneFocusRequest,
                        onDisplayedDocumentChange: { windowState.reportDisplayed($0) },
                        onPaneInteraction: { _ in windowState.find.notePaneInteraction() },
                        onVisibleRowsChange: { windowState.find.noteVisibleRows($0, contentID: $1) },
                        onPaneFocusApplied: { windowState.find.acknowledgePaneFocus(id: $0) }
                    )
                    if previewing, let preview = loader.imagePreview {
                        ImagePreviewView(preview: preview)
                    }
                }
            case .binary?:
                if let preview = loader.imagePreview {
                    ImagePreviewView(preview: preview)
                } else {
                    ContentUnavailableView(
                        "Binary file", systemImage: "doc.zipper", description: Text("Binary files are not shown."))
                }
            case .identical?:
                ContentUnavailableView(
                    "No differences", systemImage: "equal.circle",
                    description: Text("Both versions have identical content."))
            case .changeset?:
                // Stage 3 draws the changeset; this view only ever shows one file.
                Color.clear
            case nil:
                Color.clear
            }
        }
    }
}
