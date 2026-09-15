import SwiftUI

/// Header plus side-by-side panes for the selected file.
struct DiffDetailView: View {
    @Environment(WindowState.self) private var windowState
    @Environment(Preferences.self) private var preferences
    let file: ChangedFile

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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let original = file.originalPath {
                        Text("← \(original)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    Text(file.kind.label)
                    Text(file.area.comparisonLabel)
                    if case let .text(doc)? = loader.content, let language = doc.language {
                        Text(language)
                    }
                    if case let .text(doc)? = loader.content {
                        ChangeCounterText(count: doc.changeBlocks.count, current: windowState.currentChangeIndex)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            LoadingIndicator(isLoading: loader.isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func content(loader: DiffLoader) -> some View {
        if let message = loader.errorMessage {
            ContentUnavailableView(
                "Couldn't load diff", systemImage: "exclamationmark.triangle", description: Text(message))
        } else {
            switch loader.content {
            case let .text(document)?:
                SideBySideView(
                    content: .file(document),
                    styles: loader.styles,
                    fontSize: preferences.fontSize,
                    scrollTarget: windowState.scrollTarget,
                    currentBlock: windowState.currentChangeIndex,
                    collapseUnchanged: preferences.collapseUnchanged,
                    foldOptions: preferences.foldOptions
                )
            case .binary?:
                ContentUnavailableView(
                    "Binary file", systemImage: "doc.zipper", description: Text("Binary files are not shown."))
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
