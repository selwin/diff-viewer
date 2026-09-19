import SwiftUI

/// Header plus side-by-side panes for every changed file at once. The same shape as
/// `DiffDetailView`, but the header is sticky: it names whichever file owns the row at
/// the top of the viewport, so it reads as a pinned copy of that file's band.
struct ChangesetDetailView: View {
    @Environment(WindowState.self) private var windowState
    @Environment(Preferences.self) private var preferences
    /// Reported by the panes. Tied to the document that produced it, because this view
    /// stays alive across changeset selections and a bare index could name the wrong
    /// file in a replacement.
    @State private var topVisibleSection: VisibleSectionReference?

    var body: some View {
        let loader = windowState.diffLoader
        VStack(spacing: 0) {
            header(loader: loader)
            Divider()
            content(loader: loader)
        }
    }

    /// Shows the visible file, or a fixed-height loading shell until one is reported.
    @ViewBuilder
    private func header(loader: DiffLoader) -> some View {
        let progressText = loadingProgressText(loader: loader)
        if case let .changeset(document)? = loader.content,
            let reference = topVisibleSection,
            reference.loadID == document.loadID,
            document.sections.indices.contains(reference.sectionIndex)
        {
            let section = document.sections[reference.sectionIndex]
            FileHeaderView(
                file: section.file,
                stats: ChangesetChurn.stats(
                    for: section, currentFile: windowState.files.first { $0.id == section.file.id }),
                isLoading: loader.isLoading,
                loadingProgressText: progressText
            )
        } else {
            HeaderStrip(isLoading: loader.isLoading, loadingProgressText: progressText) { Spacer() }
        }
    }

    private func loadingProgressText(loader: DiffLoader) -> String? {
        guard loader.isLoading, let progress = loader.changesetProgress else { return nil }
        return "Loading \(progress.completed) of \(progress.total)…"
    }

    @ViewBuilder
    private func content(loader: DiffLoader) -> some View {
        if let message = loader.errorMessage {
            ContentUnavailableView(
                "Couldn't load diff", systemImage: "exclamationmark.triangle", description: Text(message))
        } else if case let .changeset(document)? = loader.content {
            SideBySideView(
                content: .changeset(document),
                styles: loader.styles,
                fontSize: preferences.fontSize,
                scrollTarget: windowState.scrollTarget,
                currentBlock: windowState.currentChangeIndex,
                collapseUnchanged: preferences.collapseUnchanged,
                foldOptions: preferences.foldOptions,
                onTopVisibleSectionChange: { topVisibleSection = $0 }
            )
        } else if loader.isLoading {
            // Nothing published yet. The panes appear with the first section rather than
            // flashing an empty state on the way there.
            Color.clear
        } else {
            // The assembler publishes nothing for an empty list, so this is also what a
            // repository with no changes at all shows.
            ContentUnavailableView(
                "No changes", systemImage: "equal.circle", description: Text(emptyDescription))
        }
    }

    private var emptyDescription: String {
        windowState.scope == .workingTree
            ? "The working tree matches the last commit." : "This commit changed no files."
    }
}
