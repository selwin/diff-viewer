import Foundation
import Testing

@testable import DiffViewer

struct LineStatsTotalTests {
    @Test func emptyListHasNoTotal() {
        #expect(LineStats.total(of: []) == nil)
    }

    @Test func unknownStatsHaveNoTotal() {
        let files = [changedFile("a.swift"), changedFile("b.swift")]
        #expect(LineStats.total(of: files) == nil)
    }

    @Test func binaryOnlyHasNoTotal() {
        let files = [
            changedFile("a.png").with(lineStats: .binary(nil)),
            changedFile("b.png").with(lineStats: .binary(nil)),
        ]
        #expect(LineStats.total(of: files) == nil)
    }

    @Test func mixedListSumsOnlyCountedEntries() {
        let files = [
            changedFile("a.swift").with(lineStats: .counted(added: 3, deleted: 1)),
            changedFile("b.png").with(lineStats: .binary(nil)),
            changedFile("c.swift"),
            changedFile("d.swift").with(lineStats: .counted(added: 0, deleted: 7)),
        ]
        #expect(LineStats.total(of: files) == .counted(added: 3, deleted: 8))
    }

    @Test func samePathInBothAreasCountsTwice() {
        let files = [
            changedFile("a.swift", area: .staged).with(lineStats: .counted(added: 2, deleted: 1)),
            changedFile("a.swift", area: .unstaged).with(lineStats: .counted(added: 2, deleted: 1)),
        ]
        #expect(LineStats.total(of: files) == .counted(added: 4, deleted: 2))
    }
}
