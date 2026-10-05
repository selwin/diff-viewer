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
            // Tighter, because the title's descender space already reads as part of the gap;
            // this makes the visible gap above the editor match the one below it.
            VStack(alignment: .leading, spacing: 12) {
                header(summary)
                editor
            }
            caption
            actions
        }
        .padding(22)
        // Fits a 70-character message line, git's usual wrap width, without wrapping.
        .frame(width: 500)
        // The same translucent material as the branch and commit pickers, rather than opaque white.
        .presentationBackground(.regularMaterial)
        .onAppear { editorFocused = true }
    }

    // MARK: Header

    private func header(_ summary: StagingTraySummary) -> some View {
        // The counts sit on the branch name's baseline, the last line on the left.
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(windowState.commitDefaults.isMerging ? "Commit merge to" : "Commit to")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                // The branch picker header's title, so the two read as one family.
                branchName
                    .font(.system(size: 15, weight: .semibold))
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
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(summary.fileCountText)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
            if let counts {
                Text("+\(Self.compact(counts.added))")
                    .foregroundStyle(Color(nsColor: CommitSheetPalette.addedText))
                if counts.deleted > 0 {
                    Text("−\(Self.compact(counts.deleted))")
                        .foregroundStyle(Color(nsColor: CommitSheetPalette.removedText))
                } else {
                    Text("0").foregroundStyle(.tertiary)
                }
            }
        }
        // Level with the branch name rather than louder than it.
        .font(.system(size: 13, weight: .medium))
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

    private static let messageFont = Font.system(size: 13)

    private var editor: some View {
        @Bindable var windowState = windowState
        return TextEditor(text: $windowState.commitMessage)
            .font(Self.messageFont)
            .lineSpacing(5)
            .scrollContentBackground(.hidden)
            // With the editor's own 5pt side inset, text starts where a native text field's does.
            .padding(.vertical, 4)
            .frame(height: 120)
            // A standard text field's corner, so it reads as the system's input.
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel("Commit message")
            .focused($editorFocused)
            .overlay(alignment: .topLeading) {
                // Padded to sit where the editor's own first line starts (its 5pt side inset
                // plus the field padding), so typing does not shift the text.
                if windowState.commitMessage.isEmpty {
                    Text("Commit message")
                        .font(Self.messageFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
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
                Text("Cancel").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .neutral))
            .keyboardShortcut(.cancelAction)
            Button {
                onSubmit(windowState.commitMessage)
            } label: {
                HStack(spacing: 6) {
                    Text("Commit").font(.system(size: 13, weight: .semibold))
                    Text("⌘↩")
                        .font(.system(size: 11, weight: .medium))
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
            HStack(spacing: 5) {
                Text(generateTitle)
                    .font(.system(size: 13, weight: .semibold))
                // One slot for both, so swapping in the spinner keeps the size.
                ZStack {
                    if windowState.isGeneratingCommitMessage {
                        ProgressView().controlSize(.small).scaleEffect(0.65)
                    } else {
                        // The glyph's large lower star makes it sit low; lift it to look centered.
                        Image(systemName: "sparkles").offset(y: -2).accessibilityHidden(true)
                    }
                }
                .frame(width: 12, height: 12)
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

/// Flat 32pt capsules for the sheet's buttons, a step below the title bar's 36pt controls. The
/// capsule itself is the click target, and hover and press feedback is skipped while disabled.
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
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background { fill }
                // Disabled Commit keeps the accent fill at 40% opacity; the others fade.
                .opacity(isEnabled || appearance == .prominent ? 1 : 0.5)
                .contentShape(.capsule)
                .onHover { isHovered = $0 }
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
