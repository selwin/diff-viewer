import SwiftUI

/// The modal where the commit message is written and confirmed. The draft, whether
/// Commit is available, and the caption below the editor all come from `WindowState`;
/// Commit only reports the confirmed text, and the parent dismisses and commits.
struct CommitSheetView: View {
    @Environment(WindowState.self) private var windowState
    @FocusState private var editorFocused: Bool
    /// The draft changed while a confirmed message was on its way; say so.
    let draftChanged: Bool
    let onSubmit: (String) -> Void

    var body: some View {
        let summary = StagingTraySummary(
            stagedFiles: windowState.stagedFiles, isMerging: windowState.commitDefaults.isMerging)
        VStack(alignment: .leading, spacing: 14) {
            header(summary)
            churnBar(summary.churn)
            editor
            caption
            actions
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { editorFocused = true }
    }

    // MARK: Header

    private func header(_ summary: StagingTraySummary) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(windowState.commitDefaults.isMerging ? "COMMIT MERGE TO" : "COMMIT TO")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                branchName
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(minWidth: 48, maxWidth: .infinity, alignment: .leading)
            statistics(summary)
                .layoutPriority(1)
        }
    }

    /// Switches on `headState` because `currentBranchName` is nil both when HEAD is
    /// detached and when it has not been read yet.
    @ViewBuilder
    private var branchName: some View {
        switch windowState.headState {
        case let .named(name):
            Text(name)
        case let .detached(sha):
            Text("Detached HEAD \(Text(sha.prefix(7)).foregroundStyle(.secondary))")
        case nil:
            Text("Current branch")
        }
    }

    /// Fixed-width columns, so changing counts move nothing and the header always keeps
    /// room for the branch. A value too wide for its column scales down; the exact counts
    /// stay in the tooltip and the accessibility label.
    private func statistics(_ summary: StagingTraySummary) -> some View {
        let churn = summary.churn
        let counts: (added: Int, deleted: Int)? =
            if case let .counted(added, deleted)? = churn { (added, deleted) } else { nil }
        let label = [summary.fileCountText, churn?.spokenCounts ?? "line counts unavailable"]
            .joined(separator: ", ")
        return HStack(alignment: .bottom, spacing: 16) {
            statistic(Self.compact(windowState.stagedFiles.count), title: "FILES", width: 64)
            statistic(
                counts.map { "+\(Self.compact($0.added))" } ?? "—", title: "ADDED",
                color: counts == nil ? .secondary : .green, width: 96)
            statistic(
                counts.map { "−\(Self.compact($0.deleted))" } ?? "—", title: "REMOVED",
                color: counts == nil ? .secondary : .red, width: 96)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .help(label)
    }

    private func statistic(
        _ value: String, title: String, color: Color = .primary, width: CGFloat
    ) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value)
                .font(.system(size: 28, weight: .heavy))
                .monospacedDigit()
                .tracking(-1)
                .foregroundStyle(color)
                .minimumScaleFactor(0.5)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(width: width, alignment: .trailing)
    }

    /// Exact up to 9,999, then "12K" style.
    private static func compact(_ count: Int) -> String {
        count > 9_999 ? count.formatted(.number.notation(.compactName)) : String(count)
    }

    // MARK: Churn bar

    /// Deleted lines keep a visible sliver however few they are. The row keeps its height
    /// when nothing is drawn, so the layout does not jump as counts arrive.
    private func churnBar(_ churn: LineStats?) -> some View {
        GeometryReader { proxy in
            if case let .counted(added, deleted)? = churn, added + deleted > 0 {
                let widths = Self.barWidths(added: added, deleted: deleted, in: proxy.size.width)
                HStack(spacing: 3) {
                    if widths.added > 0 {
                        Capsule().fill(.green).frame(width: widths.added)
                    }
                    if widths.deleted > 0 {
                        Capsule().fill(.red).frame(width: widths.deleted)
                    }
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private static func barWidths(added: Int, deleted: Int, in width: CGFloat) -> (added: CGFloat, deleted: CGFloat) {
        guard added > 0, deleted > 0 else { return added > 0 ? (width, 0) : (0, width) }
        let available = width - 3
        let deletedWidth = min(available, max(5, available * CGFloat(deleted) / CGFloat(added + deleted)))
        return (available - deletedWidth, deletedWidth)
    }

    // MARK: Editor

    private var editor: some View {
        @Bindable var windowState = windowState
        return TextEditor(text: $windowState.commitMessage)
            .font(.system(size: 13, design: .monospaced))
            .lineSpacing(5)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 9)
            .padding(.vertical, 12)
            .frame(height: 132)
            .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("Commit message")
            .focused($editorFocused)
            .overlay(alignment: .topLeading) {
                // Padded to sit where the editor's own first line starts, so typing
                // does not shift the text.
                if windowState.commitMessage.isEmpty {
                    Text("Commit message, or a note for Generate")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: Caption

    /// Newest news first: a failed generation, then a reopened sheet explaining
    /// itself, then merge status before template guidance.
    private var caption: some View {
        Group {
            if let error = windowState.commitGenerationError {
                Text(error)
            } else if draftChanged {
                Text("The commit message changed. Review it before committing.")
            } else if windowState.commitDefaults.isMerging {
                Text("Merge in progress")
            } else if windowState.commitNeedsTemplateEdit {
                Text("Edit the template to commit")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            generateButton
            Spacer()
            Button {
                windowState.isCommitSheetPresented = false
            } label: {
                Text("Cancel").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .neutral))
            .keyboardShortcut(.cancelAction)
            Button {
                onSubmit(windowState.commitMessage)
            } label: {
                HStack(spacing: 8) {
                    Text("Commit").font(.system(size: 14, weight: .bold))
                    Text("⌘↩")
                        .font(.system(size: 12, weight: .medium))
                        .opacity(windowState.canCommit ? 0.7 : 1)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .prominent))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!windowState.canCommit)
            .help("Commit (⌘↩)")
        }
    }

    private var generateButton: some View {
        Button {
            windowState.generateCommitMessage()
        } label: {
            HStack(spacing: 6) {
                // One slot for both, so the capsule does not resize as the label changes.
                ZStack {
                    if windowState.isGeneratingCommitMessage {
                        ProgressView().controlSize(.small).scaleEffect(0.65)
                    } else {
                        Image(systemName: "sparkles").accessibilityHidden(true)
                    }
                }
                .frame(width: 13, height: 13)
                ZStack(alignment: .leading) {
                    // The widest title sets the width.
                    Text("Regenerate").hidden()
                    Text(generateTitle)
                }
                .font(.system(size: 13, weight: .semibold))
            }
        }
        .buttonStyle(SheetCapsuleButtonStyle(appearance: .tinted))
        .disabled(!windowState.canGenerateCommitMessage)
        .help(
            windowState.commitGenerationUnavailableReason
                ?? "Generate a commit message from the staged changes and any note you typed (⌘G)"
        )
        .keyboardShortcut("g", modifiers: .command)
    }

    private var generateTitle: String {
        if windowState.isGeneratingCommitMessage {
            "Writing…"
        } else if windowState.commitDraftMatchesGeneratedText {
            "Regenerate"
        } else {
            "Generate"
        }
    }
}

/// Flat 34pt capsules for the sheet's buttons. The capsule itself is the click target, and
/// hover and press feedback is skipped while disabled.
private struct SheetCapsuleButtonStyle: ButtonStyle {
    enum Appearance {
        case tinted
        case neutral
        case prominent
    }

    let appearance: Appearance

    func makeBody(configuration: Configuration) -> some View {
        CapsuleBody(configuration: configuration, appearance: appearance)
    }

    private struct CapsuleBody: View {
        let configuration: ButtonStyleConfiguration
        let appearance: Appearance
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(labelStyle)
                .padding(.leading, leadingPadding)
                .padding(.trailing, trailingPadding)
                .frame(height: 34)
                .background { fill }
                // Prominent swaps to a gray capsule when disabled; the others just fade.
                .opacity(isEnabled || appearance == .prominent ? 1 : 0.5)
                .contentShape(.capsule)
                .onHover { isHovered = $0 }
        }

        private var leadingPadding: CGFloat {
            switch appearance {
            case .tinted: 11
            case .neutral: 16
            case .prominent: 18
            }
        }

        private var trailingPadding: CGFloat {
            appearance == .neutral ? 16 : 14
        }

        private var labelStyle: AnyShapeStyle {
            switch appearance {
            case .tinted: AnyShapeStyle(.indigo)
            case .neutral: AnyShapeStyle(.primary)
            case .prominent:
                if isEnabled {
                    AnyShapeStyle(Self.textOnAccent)
                } else {
                    AnyShapeStyle(.tertiary)
                }
            }
        }

        /// White, except on a light accent such as yellow, where white text is hard to read.
        /// The cut-off sits above macOS's blue, orange and green so those keep white text.
        private static var textOnAccent: Color {
            guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return .white }
            func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let luminance =
                0.2126 * linear(accent.redComponent) + 0.7152 * linear(accent.greenComponent)
                + 0.0722 * linear(accent.blueComponent)
            return luminance > 0.5 ? .black : .white
        }

        @ViewBuilder
        private var fill: some View {
            let pressed = isEnabled && configuration.isPressed
            let hovered = isEnabled && isHovered
            switch appearance {
            case .tinted:
                Capsule().fill(Color.indigo.opacity(pressed ? 0.26 : hovered ? 0.19 : 0.12))
            case .neutral:
                Capsule().fill(Color(nsColor: .tertiarySystemFill))
                    .overlay { Capsule().fill(Color.primary.opacity(pressed ? 0.1 : hovered ? 0.05 : 0)) }
            case .prominent:
                if isEnabled {
                    Capsule().fill(Color(nsColor: .controlAccentColor))
                        .overlay { Capsule().fill(Color.black.opacity(pressed ? 0.16 : hovered ? 0.08 : 0)) }
                } else {
                    Capsule().fill(Color(nsColor: .tertiarySystemFill))
                }
            }
        }
    }
}
