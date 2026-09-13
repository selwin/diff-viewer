import SwiftUI

struct SidebarView: View {
    @Environment(WindowState.self) private var windowState

    var body: some View {
        @Bindable var windowState = windowState
        List(selection: $windowState.selectedFileID) {
            if !windowState.isEmpty, windowState.files.isEmpty {
                Text("No changes")
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
        }
        .listStyle(.sidebar)
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
