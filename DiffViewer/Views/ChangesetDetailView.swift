import SwiftUI

/// Header plus side-by-side panes for every changed file at once. The same shape as
/// `DiffDetailView`, but the header describes the whole list instead of one file.
struct ChangesetDetailView: View {
    @Environment(WindowState.self) private var windowState
    @Environment(Preferences.self) private var preferences

    var body: some View {
        let loader = windowState.diffLoader
        VStack(spacing: 0) {
            header(loader: loader)
            Divider()
            content(loader: loader)
        }
    }

    private func header(loader: DiffLoader) -> some View {
        HStack(spacing: 10) {
            // The same two-line stack as `DiffDetailView`, so the header keeps its height
            // when the reader switches between All changes and a file.
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    summary(loader: loader)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if loader.isLoading, let progress = loader.changesetProgress {
                Text("Loading \(progress.completed) of \(progress.total)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LoadingIndicator(isLoading: loader.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// The whole list, or the rows the reader picked out of it. The count comes from the
    /// selection rather than the document, so the header names what was asked for even
    /// while the assembler is still working through it.
    private var title: String {
        guard windowState.detailSelection != .allChanges else { return "All changes" }
        return "\(windowState.selectedFiles.count) files selected"
    }

    /// The caption line: file count, churn, change counter. Blank before the first
    /// publication, so a load in progress shows just "All changes".
    @ViewBuilder
    private func summary(loader: DiffLoader) -> some View {
        if case let .changeset(document)? = loader.content {
            let files = document.sections.count
            Text("\(files) file\(files == 1 ? "" : "s")")
            if let churn = churnText(of: document) {
                Text("·")
                Text(churn)
            }
            Text("·")
            ChangeCounterText(
                count: document.document.changeBlocks.count, current: windowState.currentChangeIndex)
        } else {
            // A blank caption keeps the header at its full height until the first
            // publication fills it in, so nothing below shifts.
            Text(" ")
        }
    }

    /// "+340 −120" for the document on screen. Text sections count their own rows; every
    /// other section follows the sidebar's counts while its file is unchanged. A side that
    /// did not change is left out, like `ChurnLabel`; no churn at all shows nothing.
    private func churnText(of document: ChangesetDocument) -> String? {
        let (added, deleted) = ChangesetChurn.total(sections: document.sections, files: windowState.files)
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if deleted > 0 { parts.append("−\(deleted)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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
                foldOptions: preferences.foldOptions
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
