import AppKit
import SwiftUI

/// The title bar's repository picker: this window's repository, the other open ones, then
/// recent ones. Choosing a row opens it through the coordinator, so an open repository focuses
/// its tab and any other opens in a new one.
struct RepositoryPickerPopover: View {
    @Environment(WindowState.self) private var windowState
    @Environment(AppServices.self) private var services

    static let width: CGFloat = 320
    /// Room for about ten rows; open repositories aren't capped like recent ones, so more scroll.
    static let maxRowsHeight: CGFloat = 460

    var body: some View {
        let coordinator = services.coordinator
        let items = RepositoryPickerItems(
            current: windowState.repositoryRoot,
            open: coordinator.openRepositoryRootsInTabOrder,
            recents: services.preferences.recentRepositoryRoots)
        let directory = coordinator.gitHubConnections
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Repositories")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            // Not lazy: every row's ⌘ shortcut stays registered while it is scrolled out of view.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items.rows) { row in
                        RepositoryPickerRow(row: row, connection: directory.connection(for: row.root)) {
                            choose(row, coordinator: coordinator)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.maxRowsHeight)
            Divider().padding(.top, 8)
            Button {
                openPanel(coordinator: coordinator)
            } label: {
                Text("Open…").frame(maxWidth: .infinity)
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .neutral))
            .padding(12)
        }
        .frame(width: Self.width)
        .onAppear { directory.revalidate(items.rows.map(\.root)) }
        .onDisappear { directory.cancelQueuedRevalidation() }
    }

    private func choose(_ row: RepositoryPickerItems.Row, coordinator: WindowCoordinator) {
        windowState.isRepositoryPickerPresented = false
        guard !row.isCurrent else { return }
        let request = WindowCoordinator.OpenRequest(url: row.root.url, origin: .window(windowState.id))
        Task { await coordinator.open(request) }
    }

    private func openPanel(coordinator: WindowCoordinator) {
        windowState.isRepositoryPickerPresented = false
        let id = windowState.id
        // Defers presenting the folder chooser after requesting popover dismissal.
        Task { @MainActor in coordinator.presentOpenPanel(from: .window(id)) }
    }
}

private struct RepositoryPickerRow: View {
    let row: RepositoryPickerItems.Row
    let connection: GitHubConnection?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let path = NSString(string: row.root.path).abbreviatingWithTildeInPath
        Button(action: action) {
            HStack(spacing: 8) {
                markColumn
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.root.name)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if row.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else if let digit = row.shortcutDigit {
                    Text("⌘\(digit)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .keyboardShortcut(row.shortcutDigit.map(Self.keyboardShortcut(for:)))
        // The path may be cut short in the middle; the tooltip shows all of it.
        .help(path)
        .accessibilityLabel("\(row.root.name), \(path)\(row.isCurrent ? ", current repository" : "")")
        .accessibilityHint(row.shortcutDigit.map { "Command \($0)" } ?? "")
    }

    /// Fixed width, so names line up whether or not a row has a mark.
    private var markColumn: some View {
        ZStack {
            if let connection, connection != .notOnGitHub {
                Image(.gitHubMark)
                    .resizable()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(GitHubMarkColor.color(for: connection))
            }
        }
        .frame(width: 13)
    }

    private var background: Color {
        if row.isCurrent { return Color.accentColor.opacity(0.15) }
        return isHovered ? Color(nsColor: .labelColor).opacity(0.08) : .clear
    }

    private static func keyboardShortcut(for digit: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character("\(digit)")), modifiers: .command)
    }
}
