import SwiftUI

/// Header plus side-by-side panes for the selected file.
struct DiffDetailView: View {
    @Environment(AppState.self) private var appState
    let file: ChangedFile

    var body: some View {
        let loader = appState.diffLoader
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
                    Text(file.area == .staged ? "HEAD → Index" : "Index → Working Tree")
                    if case let .text(doc)? = loader.content, let language = doc.language {
                        Text(language)
                    }
                    if case let .text(doc)? = loader.content {
                        Text("\(doc.changeBlocks.count) change\(doc.changeBlocks.count == 1 ? "" : "s")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if loader.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func content(loader: DiffLoader) -> some View {
        if let message = loader.errorMessage {
            ContentUnavailableView("Couldn't load diff", systemImage: "exclamationmark.triangle", description: Text(message))
        } else {
            switch loader.content {
            case let .text(document)?:
                SideBySideView(document: document, styles: loader.styles)
            case .binary?:
                ContentUnavailableView("Binary file", systemImage: "doc.zipper", description: Text("Binary files are not shown."))
            case .identical?:
                ContentUnavailableView("No differences", systemImage: "equal.circle", description: Text("Both versions have identical content."))
            case nil:
                Color.clear
            }
        }
    }
}
