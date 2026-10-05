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
        VStack(alignment: .leading, spacing: 16) {
            header(summary)
            editor
            caption
            actions
        }
        .padding(22)
        .frame(width: 540)
        // The sidebar's grey rather than the sheet's default white, so the sheet sits with the window.
        .presentationBackground(Color(nsColor: .underPageBackgroundColor))
        .onAppear { editorFocused = true }
    }

    // MARK: Header

    private func header(_ summary: StagingTraySummary) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(windowState.commitDefaults.isMerging ? "Commit merge to" : "Commit to")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                branchName
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.44)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            summaryRow(summary)
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

    /// The file count, plus line counts once known. The row never shrinks, so a long
    /// branch name truncates first; the exact counts stay in the tooltip and the
    /// accessibility label.
    private func summaryRow(_ summary: StagingTraySummary) -> some View {
        let churn = summary.churn
        let counts: (added: Int, deleted: Int)? =
            if case let .counted(added, deleted)? = churn { (added, deleted) } else { nil }
        let label = [summary.fileCountText, churn?.spokenCounts ?? "line counts unavailable"]
            .joined(separator: ", ")
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(summary.fileCountText)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            if let counts {
                Text("+\(Self.compact(counts.added))")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(nsColor: CommitSheetPalette.addedText))
                if counts.deleted > 0 {
                    Text("−\(Self.compact(counts.deleted))")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(nsColor: CommitSheetPalette.removedText))
                } else {
                    Text("0")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .help(label)
    }

    /// Exact up to 9,999, then "12K" style.
    private static func compact(_ count: Int) -> String {
        count > 9_999 ? count.formatted(.number.notation(.compactName)) : String(count)
    }

    // MARK: Editor

    private static let messageFont = Font.system(size: 14, design: .monospaced)

    private var editor: some View {
        @Bindable var windowState = windowState
        return TextEditor(text: $windowState.commitMessage)
            .font(Self.messageFont)
            .lineSpacing(5)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(height: 120)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .accessibilityLabel("Commit message")
            .focused($editorFocused)
            .overlay(alignment: .topLeading) {
                // Padded to sit where the editor's own first line starts (its 5pt text
                // inset on top of the field padding), so typing does not shift the text.
                if windowState.commitMessage.isEmpty {
                    Text("Commit message")
                        .font(Self.messageFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 21)
                        .padding(.vertical, 14)
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
        HStack(spacing: 10) {
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
                    Text("Commit").font(.system(size: 14, weight: .semibold))
                    Text("⌘↩")
                        .font(.system(size: 12, weight: .medium))
                        .opacity(0.6)
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
                .font(.system(size: 14, weight: .semibold))
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

/// Flat 36pt capsules for the sheet's buttons. The capsule itself is the click target, and
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
                .padding(.horizontal, horizontalPadding)
                .frame(height: 36)
                .background { fill }
                // Disabled Commit keeps the accent fill at 40% opacity; the others fade.
                .opacity(isEnabled || appearance == .prominent ? 1 : 0.5)
                .contentShape(.capsule)
                .onHover { isHovered = $0 }
        }

        private var horizontalPadding: CGFloat {
            appearance == .tinted ? 14 : 18
        }

        private var labelStyle: AnyShapeStyle {
            switch appearance {
            case .tinted: AnyShapeStyle(Color(nsColor: CommitSheetPalette.generateText))
            case .neutral: AnyShapeStyle(.primary)
            case .prominent: AnyShapeStyle(Self.textOnAccent)
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
                Capsule().fill(Color(nsColor: CommitSheetPalette.generateFill))
                    .overlay { Capsule().fill(Color.primary.opacity(pressed ? 0.1 : hovered ? 0.05 : 0)) }
            case .neutral:
                Capsule().fill(Color(nsColor: .tertiarySystemFill))
                    .overlay { Capsule().fill(Color.primary.opacity(pressed ? 0.1 : hovered ? 0.05 : 0)) }
            case .prominent:
                Capsule().fill(Color(nsColor: .controlAccentColor).opacity(isEnabled ? 1 : 0.4))
                    .overlay { Capsule().fill(Color.black.opacity(pressed ? 0.16 : hovered ? 0.08 : 0)) }
            }
        }
    }
}

/// Colours specific to the commit sheet.
private enum CommitSheetPalette {
    static let addedText = DiffTheme.dynamic(light: rgb(31, 157, 71), dark: rgb(48, 209, 88))
    static let removedText = DiffTheme.dynamic(light: rgb(229, 72, 61), dark: rgb(255, 69, 58))
    static let generateFill = DiffTheme.dynamic(
        light: rgb(241, 238, 255), dark: rgb(160, 140, 255, 0.2))
    static let generateText = DiffTheme.dynamic(light: rgb(106, 76, 240), dark: rgb(200, 187, 255))

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
}
