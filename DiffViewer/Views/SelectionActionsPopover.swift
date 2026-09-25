import AppKit
import SwiftUI

/// The write actions for the sidebar selection, in a panel beside the first selected row.
///
/// A full-window layer that only the panel itself hit-tests. It reads the row frames on
/// its own, so a scroll re-renders this view and not `ContentView`.
struct SelectionActionsPopover: View {
    /// Everything but geometry allows the panel; `ContentView` decides that part.
    let isAllowed: Bool
    /// The window is inactive: the panel stays, dimmed like the rest of the chrome.
    let isDimmed: Bool

    @Environment(AppServices.self) private var services
    @Environment(WindowState.self) private var windowState
    @Environment(SidebarRowFrames.self) private var rowFrames
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var containerFrame: CGRect = .zero
    /// Measured from a hidden copy, so the first placement already knows the panel's size.
    @State private var panelSize: CGSize = .zero

    var body: some View {
        let groups = windowState.selectedWriteGroups
        let fileCount = windowState.selectedFiles.count
        let placement = isAllowed ? currentPlacement : nil
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                containerFrame = $0
            }
            .overlay(alignment: .topLeading) {
                if !groups.isEmpty {
                    SelectionActionsContent(groups: groups, fileCount: fileCount, run: { _, _ in })
                        .fixedSize()
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGSize.self) {
                            $0.size
                        } action: {
                            panelSize = $0
                        }
                }
            }
            .overlay(alignment: .topLeading) {
                if let placement {
                    SelectionActionsContent(groups: groups, fileCount: fileCount, run: run)
                        .fixedSize()
                        // The content alone: a dimmed background would let the diff show through.
                        .opacity(isDimmed ? 0.6 : 1)
                        .background { SelectionActionsChrome(arrowY: placement.arrowY) }
                        .disabled(windowState.isSwitchingBranch)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Selection actions")
                        .offset(x: placement.origin.x, y: placement.origin.y)
                        .transition(
                            .scale(scale: 0.92, anchor: appearanceAnchor(placement)).combined(with: .opacity)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.15)))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: placement)
    }

    /// Where the appearing panel grows from: the arrow's level on its leading edge. The
    /// transition wraps the offset, so the anchor is in units of the panel's unmoved frame.
    private func appearanceAnchor(_ placement: SelectionPopoverPlacement) -> UnitPoint {
        guard panelSize.width > 0, panelSize.height > 0 else { return .leading }
        let y = placement.origin.y + (placement.arrowY ?? panelSize.height / 2)
        return UnitPoint(x: placement.origin.x / panelSize.width, y: y / panelSize.height)
    }

    /// Converts the stored `.global` frames into this layer's space once, then places.
    private var currentPlacement: SelectionPopoverPlacement? {
        let rows = windowState.sidebarRows.map(\.id)
        guard let firstID = windowState.selectedFiles.first?.id, let index = rows.firstIndex(of: firstID) else {
            return nil
        }
        let origin = containerFrame.origin
        let stored = rowFrames.firstSelectedRow
        let rowFrame = SelectionPopoverPlacement.rowFrame(
            stored?.frame, measuredFor: stored?.id, firstSelectedID: firstID)
        return SelectionPopoverPlacement.place(
            rowFrame: rowFrame?.offsetBy(dx: -origin.x, dy: -origin.y),
            selectedRowIndex: index,
            mountedIndexRange: SelectionPopoverPlacement.mountedIndexRange(of: rowFrames.mountedRowIDs, in: rows),
            visibleListFrame: rowFrames.visibleListFrame.offsetBy(dx: -origin.x, dy: -origin.y),
            containerSize: containerFrame.size,
            popoverSize: panelSize)
    }

    /// The same runner as the context menu and the Changes menu, so Discard still confirms.
    private func run(_ action: FileAction, on files: [ChangedFile]) {
        let runner = FileActionRunner(windowState: windowState, services: services)
        Task { await runner.run(action, on: files) }
    }
}

/// The caption and one button per write group.
private struct SelectionActionsContent: View {
    let groups: [FileAction.WriteGroup]
    let fileCount: Int
    let run: (FileAction, [ChangedFile]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fileCount == 1 ? "1 file selected" : "\(fileCount) files selected")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(groups, id: \.action) { group in
                Button {
                    run(group.action, group.files)
                } label: {
                    SelectionActionLabel(action: group.action, title: group.action.compactTitle(for: group.files))
                }
                .buttonStyle(SelectionActionButtonStyle(role: SelectionActionButtonStyle.Role(group.action)))
                // Clicking the panel must leave the list focused, or the panel would hide itself.
                .focusable(false)
                .focusEffectDisabled()
                .accessibilityLabel(Self.accessibilityLabel(for: group.action, on: group.files))
            }
        }
        .padding(6)
    }

    /// Always counted: a lone "Stage" reads well beside a highlighted row, not out loud.
    private static func accessibilityLabel(for action: FileAction, on selected: [ChangedFile]) -> String {
        let files = selected.count == 1 ? "1 file" : "\(selected.count) files"
        switch action {
        case .stage: return "Stage \(files)"
        case .unstage: return "Unstage \(files)"
        // Matches the visible label, which says Restore when every file is a deletion.
        case .discard:
            return selected.allSatisfy { $0.kind == .deleted } ? "Restore \(files)" : "Discard changes to \(files)"
        case .trash: return "Move \(files) to the Trash"
        case .revealInFinder, .openInEditor, .copyPath: return action.title(for: [])
        }
    }
}

private struct SelectionActionLabel: View {
    let action: FileAction
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
            Text(title)
            Spacer(minLength: 16)
            if let shortcut {
                Text(shortcut).opacity(0.6)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch action {
        case .stage: "plus"
        case .unstage: "minus"
        case .discard: "arrow.uturn.backward"
        case .trash: "trash"
        case .revealInFinder, .openInEditor, .copyPath: "ellipsis"
        }
    }

    /// The Changes menu's shortcuts; Move to Trash has none there either.
    private var shortcut: String? {
        switch action {
        case .stage: "⌘S"
        case .unstage: "⇧⌘S"
        case .discard: "⌘⌫"
        case .trash, .revealInFinder, .openInEditor, .copyPath: nil
        }
    }
}

/// Stage is the primary action; Discard and Move to Trash are red.
private struct SelectionActionButtonStyle: ButtonStyle {
    enum Role {
        case primary, plain, destructive

        init(_ action: FileAction) {
            switch action {
            case .stage: self = .primary
            case .discard, .trash: self = .destructive
            case .unstage, .revealInFinder, .openInEditor, .copyPath: self = .plain
            }
        }
    }

    let role: Role

    func makeBody(configuration: Configuration) -> some View {
        SelectionActionButton(configuration: configuration, role: role)
    }
}

private struct SelectionActionButton: View {
    let configuration: ButtonStyleConfiguration
    let role: SelectionActionButtonStyle.Role
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        switch role {
        case .primary: .white
        case .plain: .primary
        case .destructive: .red
        }
    }

    private var background: Color {
        let highlight = isEnabled && (isHovered || configuration.isPressed)
        switch role {
        case .primary:
            return configuration.isPressed ? Color.accentColor.opacity(0.8) : Color.accentColor
        case .plain, .destructive:
            return highlight ? Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08) : .clear
        }
    }
}

/// The panel's background, hairline, shadow and arrow, drawn beneath the content. It
/// reaches left past the content by the arrow's width.
private struct SelectionActionsChrome: View {
    let arrowY: CGFloat?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = SelectionPanelShape(arrowY: arrowY)
        ZStack {
            // The shadow's source is opaque; the mask keeps only what falls outside the
            // panel, so the translucent material above does not show it through.
            shape.fill(.black)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
                .mask { SelectionPanelOutside(arrowY: arrowY).fill(style: FillStyle(eoFill: true)) }
            Group {
                if reduceTransparency || contrast == .increased {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    PopoverMaterial()
                }
            }
            .clipShape(shape)
            shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .padding(.leading, -SelectionPanelShape.arrowWidth)
    }
}

/// A rounded rectangle with a left-pointing arrow in a strip `arrowWidth` wide on its
/// leading side; with no arrow, the strip stays empty.
private struct SelectionPanelShape: Shape {
    static let arrowWidth: CGFloat = 7
    let arrowY: CGFloat?

    func path(in rect: CGRect) -> Path {
        let body = CGRect(
            x: rect.minX + Self.arrowWidth, y: rect.minY, width: rect.width - Self.arrowWidth,
            height: rect.height)
        let panel = Path(roundedRect: body, cornerRadius: SelectionPopoverPlacement.cornerRadius, style: .continuous)
        guard let arrowY else { return panel }
        let half = SelectionPopoverPlacement.arrowHalfHeight
        var arrow = Path()
        // Starts a point inside the body so the union leaves no seam along the edge.
        arrow.move(to: CGPoint(x: body.minX + 1, y: rect.minY + arrowY - half))
        arrow.addLine(to: CGPoint(x: rect.minX, y: rect.minY + arrowY))
        arrow.addLine(to: CGPoint(x: body.minX + 1, y: rect.minY + arrowY + half))
        arrow.closeSubpath()
        return panel.union(arrow)
    }
}

/// Everything around the panel, for masking its shadow; filled even-odd.
private struct SelectionPanelOutside: Shape {
    let arrowY: CGFloat?

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -40, dy: -40))
        path.addPath(SelectionPanelShape(arrowY: arrowY).path(in: rect))
        return path
    }
}

private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.clipsToBounds = true
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
