import AppKit
import SwiftUI

/// The title bar's GitHub popover: whether origin is connected, why not, and what to do about it.
/// Sign-in itself stays in Terminal: the popover offers the command, and Check Again, or
/// the app becoming active, picks the result up.
struct GitHubPopover: View {
    @Environment(WindowState.self) private var windowState

    static let width: CGFloat = 272
    private static let installGuide = URL(string: "https://cli.github.com")

    var body: some View {
        let model = windowState.gitHubConnectionModel
        let connection = model?.connection
        let repository: GitHubRepository? =
            if case let .repository(origin)? = model?.origin { origin } else { connection?.repository }
        let content = GitHubPopoverContent.make(connection: connection, showsProgress: model?.showsProgress ?? false)
        VStack(alignment: .leading, spacing: 12) {
            if let repository { header(repository, connection: connection) }
            card(content)
            ForEach(content.commands, id: \.text) { command in
                VStack(alignment: .leading, spacing: 6) {
                    CommandField(command: command.text)
                    if let hint = command.hint {
                        Text(LocalizedStringKey(Self.unbrokenFlags(hint)))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if content.linksToInstallGuide, let guide = Self.installGuide {
                Button("Other ways to install") { _ = windowState.openURL(guide) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            ForEach(content.actions, id: \.title) { action in
                Button {
                    perform(action)
                } label: {
                    Text(action.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(SheetCapsuleButtonStyle(appearance: content.isPrimary(action) ? .prominent : .neutral))
            }
        }
        .padding(16)
        .frame(width: Self.width)
    }

    /// Non-breaking hyphens, so a wrapped command breaks between words, never inside `--hostname`.
    /// Display only, in text that can't be selected: Copy takes the original text.
    static func unbrokenFlags(_ text: String) -> String {
        text.replacingOccurrences(of: "-", with: "\u{2011}")
    }

    private func header(_ repository: GitHubRepository, connection: GitHubConnection?) -> some View {
        let isPrivate = if case .connected(_, _, _, true, _)? = connection { true } else { false }
        return HStack(spacing: 10) {
            Image(.gitHubMark)
                .resizable()
                .frame(width: 26, height: 26)
                .foregroundStyle(GitHubMarkColor.color(for: connection))
            VStack(alignment: .leading, spacing: 1) {
                Text(repository.fullName)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isPrivate ? "github.com · private" : "github.com")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func card(_ content: GitHubPopoverContent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            glyph(content.glyph)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                ForEach(content.lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // The text takes the card's width; a spacer beside it would claim half.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quinary))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func glyph(_ glyph: GitHubPopoverContent.Glyph) -> some View {
        switch glyph {
        case .progress:
            ProgressView().controlSize(.small)
        case .connected:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15)).foregroundStyle(.orange)
        case .offline:
            Image(systemName: "wifi.slash").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    private func perform(_ action: GitHubPopoverContent.Action) {
        switch action {
        case let .openOnGitHub(url):
            _ = windowState.openURL(url)
            windowState.isGitHubPopoverPresented = false
        case .checkAgain:
            windowState.recheckGitHubConnection(refreshingEnvironment: true)
        case .openTerminal:
            // Only launches Terminal; the reader pastes the command themselves.
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            else { return }
            NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// A command to copy, in a monospaced field.
private struct CommandField: View {
    let command: String
    @State private var isCopied = false
    /// Bumped per click, so the reset restarts instead of an earlier one cutting a later one short.
    @State private var copies = 0

    var body: some View {
        HStack(spacing: 8) {
            // Not selectable: the shown text has non-breaking hyphens, so Copy is the only way to copy.
            Text(GitHubPopover.unbrokenFlags(command))
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                // Both drawn, so the button keeps its width when the checkmark replaces the label.
                Text("Copy")
                    .opacity(isCopied ? 0 : 1)
                    .overlay { Image(systemName: "checkmark").opacity(isCopied ? 1 : 0) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(isCopied ? "Copied" : "Copy command")
        }
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quinary))
        .task(id: copies) {
            guard copies > 0 else { return }
            // Cancelled by the next click or by the field going away.
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            isCopied = false
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        isCopied = true
        copies += 1
    }
}
