import SwiftUI

struct SidebarView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        @Bindable var windowState = windowState
        List(selection: $windowState.selectedFileID) {
            if !windowState.isEmpty, windowState.files.isEmpty {
                Text(windowState.scope == .workingTree ? "No changes" : "No changes in this commit")
                    .foregroundStyle(.secondary)
            }
            if !windowState.unstagedFiles.isEmpty {
                Section("Unstaged (\(windowState.unstagedFiles.count))") {
                    ForEach(windowState.unstagedFiles) { FileRow(file: $0) }
                }
            }
            if !windowState.stagedFiles.isEmpty {
                Section("Staged (\(windowState.stagedFiles.count))") {
                    ForEach(windowState.stagedFiles) { FileRow(file: $0) }
                }
            }
            // A commit has one list: its own staging is long settled.
            if !windowState.commitFiles.isEmpty {
                Section("Changed (\(windowState.commitFiles.count))") {
                    ForEach(windowState.commitFiles) { FileRow(file: $0) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !windowState.isEmpty {
                VStack(spacing: 0) {
                    CommitPickerView()
                    Divider()
                }
                .background(.bar)
            }
        }
    }
}

private struct FileRow: View {
    let file: ChangedFile

    var body: some View {
        HStack(spacing: 8) {
            Text(String(file.kind.rawValue))
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(badgeColor, in: RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            ChurnLabel(stats: file.lineStats)
        }
        .tag(file.id)
        .help(file.originalPath.map { "\(file.kind.label) from \($0)" } ?? file.kind.label)
    }

    private var badgeColor: Color {
        switch file.kind {
        case .modified, .typeChanged: .orange
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        case .unmerged: .purple
        }
    }
}

private struct ChurnLabel: View {
    let stats: LineStats?

    var body: some View {
        switch stats {
        case nil:
            EmptyView()
        case .binary:
            Text("binary")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()
                .lineLimit(1)
                .help("Binary file")
        case .counted(let added, let deleted):
            // A side that did not change is left out, so a pure addition reads "+12"
            // rather than "+12 −0"; a file with no churn at all shows nothing.
            HStack(spacing: 4) {
                if added > 0 {
                    Text("+\(added)").foregroundStyle(.green)
                }
                if deleted > 0 {
                    Text("−\(deleted)").foregroundStyle(.red)
                }
            }
            .font(.system(.callout, design: .monospaced))
            .fixedSize()
            .lineLimit(1)
            .help(countedHelpText(added: added, deleted: deleted))
        }
    }

    private func countedHelpText(added: Int, deleted: Int) -> String {
        let addedLabel = added == 1 ? "1 line added" : "\(added) lines added"
        let deletedLabel = deleted == 1 ? "1 line deleted" : "\(deleted) lines deleted"
        return "\(addedLabel), \(deletedLabel)"
    }
}
