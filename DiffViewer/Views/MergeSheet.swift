import SwiftUI

/// Confirms merging a branch into the current one: the commits it brings in and any
/// conflicts predicted. Merge and Cancel only report; the parent dismisses and merges,
/// and git's refusal arrives as the window's error.
struct MergeSheet: View {
    @State private var model: MergeSheetModel
    /// Read once per presentation so "Today" does not shift while the sheet is up.
    @State private var grouping = CommitDayGrouping()
    let onMerge: (MergeTarget) -> Void
    let onCancel: () -> Void

    init(model: MergeSheetModel, onMerge: @escaping (MergeTarget) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onMerge = onMerge
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(model.target.sourceName) into \(model.target.destinationBranch)")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            commitList
            notice
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Merge") { onMerge(model.target) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canMerge)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var commitList: some View {
        if model.isLoadingCommits {
            ProgressView().controlSize(.small)
        } else if model.commits == nil {
            Text("Couldn't list the commits").font(.callout).foregroundStyle(.secondary)
        } else if !model.shownCommits.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.shownCommits) { commit in
                    row(commit)
                }
                if let more = model.moreCommitsText {
                    Text(more).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ commit: CommitSummary) -> some View {
        let detail = " · \(commit.author) · \(grouping.commitDateText(for: commit.committedAt))"
        return Text("\(Text(verbatim: commit.subject))\(Text(verbatim: detail).foregroundStyle(.secondary))")
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var notice: some View {
        if let conflicts = model.conflictText {
            Label(conflicts, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(4)
                .truncationMode(.middle)
        } else if model.isAlreadyMerged {
            Text("Already merged — nothing to merge.").font(.callout).foregroundStyle(.secondary)
        } else if model.previewStatus == .unavailable {
            Text("Couldn't predict conflicts.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
