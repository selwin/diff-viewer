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

    init(model: MergeSheetModel, onMerge: @escaping (MergeTarget) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onMerge = onMerge
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Merge Branch").font(.system(size: 15, weight: .semibold))
            overview
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
        .glassSheetBackground()
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Overview

    /// The status box is centred under the merge commit, so it sits
    /// `illustrationHeight - mergeCommitY + statusGap` below the commit's centre.
    private var overview: some View {
        VStack(alignment: .leading, spacing: MergeOverviewLayout.statusGap) {
            MergeIllustration(
                sourceName: model.target.sourceName,
                destinationName: model.target.destinationBranch,
                marks: model.commitMarks,
                commitsText: model.commitsText,
                marker: marker,
                accessibilityLabel: model.accessibilityLabel)
            statusSlot
                .padding(.leading, MergeOverviewLayout.mergeCommitX - MergeOverviewLayout.statusSlotWidth / 2)
        }
    }

    private var marker: MergeIllustration.Marker {
        switch model.outcome {
        case .clean: .clean
        case .conflicts: .conflict
        case .checking, .alreadyMerged, .unknown: .neutral
        }
    }

    // MARK: Status

    /// The box hugs short text and wraps long text at the slot's width. `ViewThatFits`
    /// rather than a max-width frame, which would always stretch to the cap.
    private var statusSlot: some View {
        ViewThatFits(in: .horizontal) {
            statusBox.fixedSize()
            statusBox.fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: MergeOverviewLayout.statusSlotWidth)
    }

    private var statusBox: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.statusTitle)
                .font(.system(size: 13))
                .foregroundStyle(titleColor)
            statistics
        }
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14).fill(MergeSheetPalette.cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: 14).strokeBorder(MergeSheetPalette.cardBorder, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private var titleColor: Color {
        model.outcome == .conflicts ? Color(nsColor: .systemOrange) : .primary
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
        .background(RoundedRectangle(cornerRadius: 16).fill(MergeSheetPalette.cardFill))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16).strokeBorder(MergeSheetPalette.cardBorder, lineWidth: 0.5)
        )
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

/// Colours shared by the Merge sheet and its illustration.
enum MergeSheetPalette {
    /// The card behind the current branch, the status box and the conflict list.
    static let cardFill = Color(nsColor: DiffTheme.dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.08)))
    static let cardBorder = Color(
        nsColor: DiffTheme.dynamic(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.10)))
}
