import SwiftUI

/// Confirms merging a branch into the current one: the predicted outcome, how much it
/// changes and any conflicts. Merge and Cancel only report; the parent dismisses and
/// merges, and git's refusal arrives as the window's error.
struct MergeSheet: View {
    @State private var model: MergeSheetModel
    @State private var isExpanded = false
    let onMerge: (MergeTarget) -> Void
    let onCancel: () -> Void

    private static let collapsedRowCount = 3
    private static let rowHeight: CGFloat = 32
    private static let separatorHeight: CGFloat = 0.5
    private static let maxListHeight: CGFloat = 224
    private static let panelFill = Color(nsColor: .quaternarySystemFill)
    private static let statusBoxMaxWidth: CGFloat = 216

    init(model: MergeSheetModel, onMerge: @escaping (MergeTarget) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onMerge = onMerge
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Merge Branch").font(.system(size: 15, weight: .semibold))
            illustration
            HStack {
                Spacer(minLength: 0)
                statusSlot
            }
            if !model.conflicts.isEmpty { conflictPanel }
            if let note = model.conflictNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(24)
        .frame(width: 500)
        .presentationBackground(.regularMaterial)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Illustration

    /// A plain stand-in until the drawing replaces it.
    private var illustration: some View {
        VStack(spacing: 6) {
            Text(verbatim: model.target.sourceName)
            if let commitsText = model.commitsText { Text(commitsText).foregroundStyle(.secondary) }
            Text(verbatim: model.target.destinationBranch)
        }
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: 452, height: 96)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
    }

    // MARK: Status

    /// The box hugs short text and wraps long text at the slot's width. `ViewThatFits`
    /// rather than a max-width frame, which would always stretch to the cap.
    private var statusSlot: some View {
        ViewThatFits(in: .horizontal) {
            statusBox.fixedSize()
            statusBox.fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.statusBoxMaxWidth)
    }

    private var statusBox: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                statusIcon.frame(width: 14, height: 14)
                Text(model.statusTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(titleColor)
            }
            statistics
        }
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14).fill(Self.panelFill))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.outcome {
        case .checking:
            ProgressView().controlSize(.mini)
        case .clean:
            Image(systemName: "checkmark").foregroundStyle(Color(nsColor: .systemGreen))
        case .conflicts:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(nsColor: .systemOrange))
        case .alreadyMerged:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .unknown:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private var titleColor: Color {
        model.outcome == .conflicts ? Color(nsColor: MergeSheetPalette.warningText) : .primary
    }

    @ViewBuilder
    private var statistics: some View {
        switch model.statistics {
        case .hidden:
            EmptyView()
        case .pending:
            // Holds one line so the box does not jump when the counts arrive; a result that
            // wraps can still make it taller.
            Text(" ").font(.system(size: 12)).accessibilityHidden(true)
        case let .ready(files, added, deleted):
            Text(
                "\(Text(files).foregroundStyle(.secondary))  \(Text(added).foregroundStyle(Color(nsColor: DiffTheme.addedCount)))  \(Text(deleted).foregroundStyle(Color(nsColor: DiffTheme.deletedCount)))"
            )
            .font(.system(size: 12))
        }
    }

    // MARK: Conflicts

    private var hiddenConflictCount: Int { max(0, model.conflicts.count - Self.collapsedRowCount) }

    private var conflictPanel: some View {
        Group {
            if isExpanded {
                ScrollView {
                    LazyVStack(spacing: 0) { conflictRows(model.conflicts) }
                }
                .frame(height: expandedHeight)
            } else {
                VStack(spacing: 0) {
                    conflictRows(Array(model.conflicts.prefix(Self.collapsedRowCount)))
                    if hiddenConflictCount > 0 { showMoreRow }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Self.panelFill))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var expandedHeight: CGFloat {
        let count = CGFloat(model.conflicts.count)
        let natural = count * Self.rowHeight + max(0, count - 1) * Self.separatorHeight
        return min(natural, Self.maxListHeight)
    }

    private func conflictRows(_ conflicts: [MergeConflict]) -> some View {
        ForEach(Array(conflicts.enumerated()), id: \.element.path) { index, conflict in
            VStack(spacing: 0) {
                if index > 0 { hairline }
                conflictRow(conflict)
            }
        }
    }

    private func conflictRow(_ conflict: MergeConflict) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: conflict.path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(conflict.path)
            Spacer(minLength: 0)
            Text(conflict.kind.label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
    }

    private var showMoreRow: some View {
        VStack(spacing: 0) {
            hairline
            Button {
                isExpanded = true
            } label: {
                HStack(spacing: 4) {
                    Text("Show \(hiddenConflictCount) More")
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .frame(height: Self.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: Self.separatorHeight)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(action: onCancel) {
                Text("Cancel").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .neutral))
            .keyboardShortcut(.cancelAction)
            Button {
                onMerge(model.target)
            } label: {
                HStack(spacing: 6) {
                    Text(model.primaryTitle).font(.system(size: 13, weight: .semibold))
                    Text("⌘↩")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.6)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(SheetCapsuleButtonStyle(appearance: .prominent))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canMerge)
            .help("\(model.primaryTitle) (⌘↩)")
        }
    }
}

extension MergeConflictKind {
    fileprivate var label: String {
        switch self {
        case .contents: "Both modified"
        case .addAdd: "Both added"
        case .modifyDelete: "Modified and deleted"
        case .renameDelete: "Renamed and deleted"
        case .renameRename: "Renamed twice"
        case .fileDirectory: "File/directory conflict"
        case .other: "Conflict"
        }
    }
}

/// Colours specific to the Merge sheet.
private enum MergeSheetPalette {
    /// System orange is too light for 12pt text on the light fill; this darker amber reads
    /// at about 4.9:1. Dark appearance keeps system orange, which already contrasts well.
    static let warningText = DiffTheme.dynamic(light: rgb(160, 78, 0), dark: .systemOrange)

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
}
