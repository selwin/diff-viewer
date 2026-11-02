import SwiftUI

/// The title bar's repository capsule: a GitHub mark that shows whether origin is connected and
/// opens the GitHub popover, then the repository name, which opens the repository picker. The
/// mark shows only while origin is a GitHub repository.
struct RepositoryCapsuleView: View {
    @Environment(WindowState.self) private var windowState
    @State private var isMarkTinted = false
    @State private var isNameTinted = false

    /// The same on both sides of the divider, so the mark and the name sit evenly around it.
    private static let dividerGap: CGFloat = 10

    var body: some View {
        @Bindable var windowState = windowState
        let model = windowState.gitHubConnectionModel
        let showsMark = if case .repository? = model?.origin { true } else { false }
        HStack(spacing: 0) {
            if showsMark {
                markSegment(connection: model?.connection)
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 20)
                    // Steps aside for a tinted neighbour, as the branch pill's divider does.
                    .opacity(isMarkTinted || isNameTinted ? 0 : 1)
            }
            // Capped like the pickers beside it, so a long name can't push the toolbar's other
            // items into overflow.
            CappedWidth(maximumWidth: 300) {
                nameSegment(leading: showsMark ? Self.dividerGap : 14)
            }
        }
        .clipShape(Capsule())
        .glassEffect(in: .capsule)
    }

    private func markSegment(connection: GitHubConnection?) -> some View {
        @Bindable var windowState = windowState
        let status = connection.statusText
        return Button {
            windowState.openGitHubPopover()
        } label: {
            Image(.gitHubMark)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(GitHubMarkColor.color(for: connection))
                // The round end needs more room than the divider side, where the gap matches the name's.
                .padding(.leading, 14)
                .padding(.trailing, Self.dividerGap)
                .frame(height: 36)
                .modifier(
                    PillPartHover(isPopoverPresented: windowState.isGitHubPopoverPresented) { isMarkTinted = $0 })
        }
        .buttonStyle(.plain)
        .disabled(!windowState.canOpenGitHubPopover)
        .help("GitHub: \(status)")
        .accessibilityLabel("GitHub, \(status)")
        .popover(isPresented: $windowState.isGitHubPopoverPresented, arrowEdge: .bottom) {
            GitHubPopover()
        }
    }

    private func nameSegment(leading: CGFloat) -> some View {
        @Bindable var windowState = windowState
        let path = NSString(string: windowState.repositoryRoot?.path ?? "").abbreviatingWithTildeInPath
        return Button {
            if windowState.canOpenRepositoryPicker { windowState.isRepositoryPickerPresented = true }
        } label: {
            HStack(spacing: 6) {
                Text(windowState.title)
                    // Larger and heavier than the pickers' labels, so the name leads the row.
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .offset(y: -TitleBarMetrics.textLift)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(y: -TitleBarMetrics.chevronLift)
            }
            .padding(.leading, leading)
            .padding(.trailing, 14)
            .frame(height: 36)
            .modifier(
                PillPartHover(isPopoverPresented: windowState.isRepositoryPickerPresented) { isNameTinted = $0 })
        }
        .buttonStyle(.plain)
        .disabled(!windowState.canOpenRepositoryPicker)
        .help(path)
        .accessibilityLabel("Repository, \(windowState.title), opens repository picker")
        .popover(isPresented: $windowState.isRepositoryPickerPresented, arrowEdge: .bottom) {
            RepositoryPickerPopover()
        }
    }
}

/// The GitHub mark's colour: full for a connected repository, quiet for every other state,
/// including one not yet known.
enum GitHubMarkColor {
    static func color(for connection: GitHubConnection?) -> Color {
        if case .connected? = connection { return Color(nsColor: .labelColor) }
        return Color(nsColor: .tertiaryLabelColor)
    }
}

extension GitHubConnection? {
    /// The state in a few words, for the mark's tooltip and spoken label.
    var statusText: String {
        switch self {
        case nil: "checking"
        case .connected?: "connected"
        case .cliNotFound?, .notSignedIn?, .notOnGitHub?: "not connected"
        case .noAccess?: "no access to this repository"
        case .unreachable?: "unreachable"
        }
    }
}
