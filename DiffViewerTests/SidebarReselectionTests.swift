import Foundation
import Testing

@testable import DiffViewer

struct SidebarReselectionTests {
    private func pending(_ path: String, area: ChangedFile.Area = .unstaged, row: Int? = nil)
        -> WindowState.PendingSelection
    {
        WindowState.PendingSelection(path: path, area: area, row: row)
    }

    @Test func thePathWinsOverTheRememberedRow() {
        let rows = [changedFile("b.swift"), changedFile("a.swift", area: .staged)]
        let target = SidebarReselection.target(for: pending("a.swift", row: 0), in: rows)
        #expect(target == rows[1].id, "staging a file moves it, and the selection follows the path")
    }

    @Test func theOriginalAreaWinsWhenThePathIsInBoth() {
        let rows = [changedFile("dup.swift"), changedFile("dup.swift", area: .staged)]
        #expect(SidebarReselection.target(for: pending("dup.swift", area: .staged), in: rows) == rows[1].id)
        #expect(SidebarReselection.target(for: pending("dup.swift", area: .unstaged), in: rows) == rows[0].id)
    }

    @Test func unstagedWinsWhenTheOriginalAreaIsGone() {
        let commit = commitSummary("c1")
        let rows = [changedFile("dup.swift"), changedFile("dup.swift", area: .staged)]
        let target = SidebarReselection.target(for: pending("dup.swift", area: .commit(commit.ref)), in: rows)
        #expect(target == rows[0].id)
    }

    @Test func anyAreaIsTakenWhenNeitherMatches() {
        let rows = [changedFile("only.swift", area: .staged)]
        let commit = commitSummary("c1")
        let target = SidebarReselection.target(for: pending("only.swift", area: .commit(commit.ref)), in: rows)
        #expect(target == rows[0].id)
    }

    @Test func theRememberedRowIsUsedWhenThePathIsGone() {
        let rows = [changedFile("a.swift"), changedFile("b.swift"), changedFile("c.swift")]
        let target = SidebarReselection.target(for: pending("gone.swift", row: 1), in: rows)
        #expect(target == rows[1].id)
    }

    @Test func theRememberedRowIsClampedToTheLastRow() {
        let rows = [changedFile("a.swift"), changedFile("b.swift")]
        let target = SidebarReselection.target(for: pending("gone.swift", row: 5), in: rows)
        #expect(target == rows[1].id, "discarding the bottom row selects the new bottom row")
    }

    @Test func anEmptyListSelectsNothing() {
        #expect(SidebarReselection.target(for: pending("a.swift", row: 0), in: []) == nil)
    }

    @Test func aMissingPathWithoutARowSelectsNothing() {
        let rows = [changedFile("a.swift"), changedFile("b.swift")]
        #expect(SidebarReselection.target(for: pending("gone.swift"), in: rows) == nil)
    }
}
