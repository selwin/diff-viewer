import Testing

@testable import DiffViewer

@Suite("DirectoryGrouping")
struct DirectoryGroupingTests {
    @Test("top-level files sort after directories within an area")
    func topLevelLast() {
        let files = [changedFile("b.swift"), changedFile("src/a.swift"), changedFile("a.swift")]
        #expect(DirectoryGrouping.sortedForDisplay(files).map(\.path) == ["src/a.swift", "a.swift", "b.swift"])
    }

    @Test("a nested directory never splits its parent's files")
    func nestedDirectoryStaysContiguous() {
        let files = [changedFile("a/z.swift"), changedFile("a/b/c.swift"), changedFile("a/b.swift")]
        let groups = DirectoryGrouping.groups(fromSortedFiles: DirectoryGrouping.sortedForDisplay(files))
        #expect(groups.map(\.directoryPath) == ["a", "a/b"])
        #expect(groups.map { $0.files.map(\.path) } == [["a/b.swift", "a/z.swift"], ["a/b/c.swift"]])
    }

    @Test("no files make no groups")
    func emptyInput() {
        #expect(DirectoryGrouping.groups(fromSortedFiles: []).isEmpty)
    }

    @Test("parent prefix and name for nested, single-component and top-level directories")
    func names() {
        let nested = DirectoryGroup(directoryPath: "DiffViewer/Views", files: [])
        #expect(nested.parentPathPrefix == "DiffViewer/")
        #expect(nested.directoryName == "Views")
        let single = DirectoryGroup(directoryPath: "DiffViewer", files: [])
        #expect(single.parentPathPrefix == "")
        #expect(single.directoryName == "DiffViewer")
        let top = DirectoryGroup(directoryPath: "", files: [])
        #expect(top.parentPathPrefix == "")
        #expect(top.directoryName == "Top level")
    }

    @Test("staged files sort first and each area groups separately")
    func areasStaySeparate() {
        let files = [
            changedFile("src/a.swift", area: .unstaged), changedFile("src/b.swift", area: .staged),
            changedFile("src/c.swift", area: .unstaged),
        ]
        let sorted = DirectoryGrouping.sortedForDisplay(files)
        #expect(sorted.map(\.path) == ["src/b.swift", "src/a.swift", "src/c.swift"])
        let staged = DirectoryGrouping.groups(fromSortedFiles: sorted.filter { $0.area == .staged })
        let unstaged = DirectoryGrouping.groups(fromSortedFiles: sorted.filter { $0.area == .unstaged })
        #expect(staged.map { $0.files.map(\.path) } == [["src/b.swift"]])
        #expect(unstaged.map { $0.files.map(\.path) } == [["src/a.swift", "src/c.swift"]])
    }
}
