import Foundation

/// A run of files in one directory, as the sidebar groups them under a directory header.
struct DirectoryGroup: Identifiable, Sendable {
    /// Relative to the repository root; `""` for files at the top level.
    let directoryPath: String
    let files: [ChangedFile]

    var id: String { directoryPath }

    /// The directory's ancestors with a trailing slash, shown dimmed before the name:
    /// `DiffViewer/` for `DiffViewer/Views`. Empty when there is no parent.
    var parentPathPrefix: String {
        guard let slash = directoryPath.lastIndex(of: "/") else { return "" }
        return String(directoryPath[...slash])
    }

    /// `parentPathPrefix` and then shorter forms that drop leading components behind "…/",
    /// ending with "", so a narrow caption shortens the path at a folder boundary rather
    /// than mid-name.
    var parentPathPrefixes: [String] {
        let components = parentPathPrefix.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return [""] }
        var forms = [parentPathPrefix]
        for dropped in 1..<components.count {
            forms.append("…/" + components[dropped...].joined(separator: "/") + "/")
        }
        forms.append("")
        return forms
    }

    var directoryName: String {
        directoryPath.isEmpty ? "Top level" : (directoryPath as NSString).lastPathComponent
    }
}

enum DirectoryGrouping {
    /// Files ordered so each directory's files are contiguous: area first, then directory,
    /// then name, with top-level files last in their area. A plain path sort would split
    /// `a/` around `a/b/` (`a/b.swift`, `a/b/c.swift`, `a/z.swift`). `.commit` areas all
    /// share a sort order, so a stash's untracked files sort in among its tracked ones.
    static func sortedForDisplay(_ files: [ChangedFile]) -> [ChangedFile] {
        files.sorted { a, b in
            let aDirectory = a.directory
            let bDirectory = b.directory
            return (a.area.sortOrder, aDirectory.isEmpty ? 1 : 0, aDirectory, a.fileName)
                < (b.area.sortOrder, bDirectory.isEmpty ? 1 : 0, bDirectory, b.fileName)
        }
    }

    /// Splits runs of equal `directory`. The input must be one list (areas of one sort
    /// order), sorted by `sortedForDisplay`; each sidebar list calls this separately, so
    /// group ids are unique within a list.
    static func groups(fromSortedFiles files: [ChangedFile]) -> [DirectoryGroup] {
        assert(
            files.allSatisfy { $0.area.sortOrder == files.first?.area.sortOrder },
            "groups(fromSortedFiles:) takes one list")
        var groups: [DirectoryGroup] = []
        var run: [ChangedFile] = []
        var runDirectory = ""
        for file in files {
            let directory = file.directory
            if !run.isEmpty, directory != runDirectory {
                groups.append(DirectoryGroup(directoryPath: runDirectory, files: run))
                run = []
            }
            runDirectory = directory
            run.append(file)
        }
        if !run.isEmpty {
            groups.append(DirectoryGroup(directoryPath: runDirectory, files: run))
        }
        return groups
    }
}
