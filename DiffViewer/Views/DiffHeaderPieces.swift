import AppKit
import SwiftUI

/// The chrome both headers share: a fixed height, the same padding and background, and
/// the loading feedback at the trailing edge. `content` goes before the trailing group
/// and is responsible for filling the width (it holds the only spacer).
struct HeaderStrip<Content: View>: View {
    static var height: CGFloat { 32 }

    let isLoading: Bool
    var loadingProgressText: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
            if let loadingProgressText {
                Text(loadingProgressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            LoadingIndicator(isLoading: isLoading)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(.bar)
    }
}

/// One file's header: kind badge, name, a copy button, and a trailing rail with the
/// directory and the churn. As the window narrows the directory gives way first, then
/// the rename source, then the name (truncated in the middle to keep its extension).
struct FileHeaderView: View {
    let file: ChangedFile
    let stats: LineStats?
    let isLoading: Bool
    var loadingProgressText: String?
    /// Nil when the file has no rendered preview to switch to.
    var showsPreview: Binding<Bool>?

    var body: some View {
        HeaderStrip(isLoading: isLoading, loadingProgressText: loadingProgressText) {
            HStack(spacing: 8) {
                KindBadge(kind: file.kind)
                    .fixedSize()
                Text(file.fileName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(2)
                    .help(file.path)
                if let original = file.originalPath {
                    Text("← \(original)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
                CopyButton(label: "Copy Relative Path", action: copyRelativePath)
                if let showsPreview {
                    Picker("View", selection: showsPreview) {
                        Label("Preview", systemImage: "photo").tag(true)
                        Label("Source", systemImage: "text.alignleft").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()
                    .layoutPriority(2)
                    .help("Show the rendered SVG or its source")
                }
                Spacer()
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(0)
                    if !ChurnLabel.isEmpty(for: stats) {
                        Divider().frame(height: 14)
                    }
                }
                ChurnLabel(stats: stats)
                    .fixedSize()
                    .layoutPriority(2)
            }
        }
    }

    /// The repo-relative path, not the absolute one `FileAction.copyPath` copies.
    private func copyRelativePath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(file.path, forType: .string)
    }
}

/// A small copy glyph: quiet at rest, lit with a soft background on hover, and a
/// green checkmark for a moment after a click so the copy is seen to happen. `label`
/// is its tooltip and accessibility label.
struct CopyButton: View {
    let label: String
    let action: () -> Void
    @State private var isHovering = false
    @State private var showsCheckmark = false
    /// The pending revert; a new click cancels it so the checkmark's time restarts.
    @State private var revert: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            Image(systemName: showsCheckmark ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.medium))
                .foregroundStyle(glyphStyle)
                .contentTransition(.symbolEffect(.replace))
                // Both glyphs share one frame so the header never shifts.
                .frame(width: 14, height: 14)
                .padding(3)
                .background(.quaternary.opacity(isHovering ? 1 : 0), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { isHovering = hovering }
        }
        .help(label)
        .accessibilityLabel(showsCheckmark ? "Copied" : label)
    }

    private var glyphStyle: AnyShapeStyle {
        if showsCheckmark { return AnyShapeStyle(.green) }
        return isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private func copy() {
        action()
        withAnimation(.easeInOut(duration: 0.2)) { showsCheckmark = true }
        revert?.cancel()
        revert = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { showsCheckmark = false }
        }
    }
}

/// The kind's letter on its colour, the same mapping the pane bands draw.
struct KindBadge: View {
    let kind: ChangedFile.Kind

    var body: some View {
        Text(String(kind.rawValue))
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Color(nsColor: DiffTheme.badge(for: kind)), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(kind.label)
    }
}

/// The small spinner a header shows while its content is being computed.
struct LoadingIndicator: View {
    let isLoading: Bool

    var body: some View {
        if isLoading {
            ProgressView().controlSize(.small)
        }
    }
}

/// The +/− counts after a file row (byte counts for a binary file), the whole list's
/// total on the All changes row, and the rail of a file header.
struct ChurnLabel: View {
    let stats: LineStats?
    /// A selected row inverts its text to white; the counts follow the file name
    /// there and let the +/− signs carry the meaning.
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.locale) private var locale

    /// True exactly when the label draws nothing: no stats, or counts that are both
    /// zero. A binary file always shows something, even if only "binary".
    static func isEmpty(for stats: LineStats?) -> Bool {
        switch stats {
        case nil: true
        case .binary: false
        case let .counted(added, deleted): added == 0 && deleted == 0
        }
    }

    var body: some View {
        switch stats {
        case nil:
            EmptyView()
        case .binary(nil):
            binaryFallback
        case let .binary(sizes?):
            if let presentation = BinaryChurnText.presentation(for: sizes, locale: locale) {
                HStack(spacing: 4) {
                    Text(presentation.primaryText).foregroundStyle(primaryStyle(for: presentation.kind))
                    if let delta = presentation.deltaText {
                        Text(delta).foregroundStyle(deltaStyle(for: presentation.kind))
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .fixedSize()
                .lineLimit(1)
                .help(presentation.helpText)
            } else {
                binaryFallback
            }
        case .counted(let added, let deleted):
            // A side that did not change is left out, so a pure addition reads "+12"
            // rather than "+12 −0"; a file with no churn at all shows nothing.
            HStack(spacing: 4) {
                if added > 0 {
                    Text("+\(added)").foregroundStyle(addedStyle)
                }
                if deleted > 0 {
                    Text("−\(deleted)").foregroundStyle(deletedStyle)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .fixedSize()
            .lineLimit(1)
            .help(countedHelpText(added: added, deleted: deleted))
        }
    }

    private var addedStyle: AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.green)
    }

    private var deletedStyle: AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.red)
    }

    /// A modified binary's size is context, not churn; only the delta is coloured.
    private var sizeStyle: AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    /// Byte counts that could not be read: still a binary, just an unsized one.
    private var binaryFallback: some View {
        Text("binary")
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.tertiary)
            .fixedSize()
            .lineLimit(1)
            .help("Binary file")
    }

    private func primaryStyle(for kind: BinaryChurnText.ChangeKind) -> AnyShapeStyle {
        switch kind {
        case .added: addedStyle
        case .deleted: deletedStyle
        case .grown, .shrunk, .sameSize: sizeStyle
        }
    }

    private func deltaStyle(for kind: BinaryChurnText.ChangeKind) -> AnyShapeStyle {
        kind == .shrunk ? deletedStyle : addedStyle
    }

    private func countedHelpText(added: Int, deleted: Int) -> String {
        let addedLabel = added == 1 ? "1 line added" : "\(added) lines added"
        let deletedLabel = deleted == 1 ? "1 line deleted" : "\(deleted) lines deleted"
        return "\(addedLabel), \(deletedLabel)"
    }
}
