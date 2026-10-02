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

    var directoryName: String {
        directoryPath.isEmpty ? "Top level" : (directoryPath as NSString).lastPathComponent
    }
}

enum DirectoryGrouping {
    /// Files ordered so each directory's files are contiguous: area first, then directory,
    /// then name, with top-level files last in their area. A plain path sort would split
    /// `a/` around `a/b/` (`a/b.swift`, `a/b/c.swift`, `a/z.swift`). `.commit` areas all
    /// share a sort order, which is fine because a list only ever holds one commit.
    static func sortedForDisplay(_ files: [ChangedFile]) -> [ChangedFile] {
        files.sorted { a, b in
            let aDirectory = a.directory
            let bDirectory = b.directory
            return (a.area.sortOrder, aDirectory.isEmpty ? 1 : 0, aDirectory, a.fileName)
                < (b.area.sortOrder, bDirectory.isEmpty ? 1 : 0, bDirectory, b.fileName)
        }
    }

    /// Splits runs of equal `directory`. The input must be one area, sorted by
    /// `sortedForDisplay`; each sidebar list calls this separately, so group ids are
    /// unique within a list.
    static func groups(fromSortedFiles files: [ChangedFile]) -> [DirectoryGroup] {
        assert(files.allSatisfy { $0.area == files.first?.area }, "groups(fromSortedFiles:) takes one area")
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
