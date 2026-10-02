import CoreGraphics
import Testing

@testable import DiffViewer

struct StagingTrayLayoutTests {
    private typealias Layout = StagingTrayLayout
    /// The measured staged-row heights at small, medium and large sidebar sizes.
    private static let small: CGFloat = 26
    private static let medium: CGFloat = 32
    private static let large: CGFloat = 40
    /// Room for every list the tray ever shows, above the chrome and the Changes floor.
    private static let tall: CGFloat = 900

    private static func listHeight(
        content: CGFloat, row: CGFloat = medium, sidebar: CGFloat = tall, holdsSelection: Bool = false,
        hasCapsule: Bool = false
    ) -> CGFloat {
        Layout.listHeight(
            contentHeight: content, rowHeight: row, sidebarHeight: sidebar, holdsSelection: holdsSelection,
            hasCapsule: hasCapsule)
    }

    /// Nothing staged, as in a merge with nothing staged yet: no list, nothing to fade.
    @Test func anEmptyTrayHasNoListAndNoOverflow() {
        let content = Layout.contentHeight(groupCount: 0, rowCount: 0, rowHeight: Self.medium)
        let height = Self.listHeight(content: content, holdsSelection: true)
        #expect(content == 0)
        #expect(height == 0)
        #expect(!Layout.overflows(contentHeight: content, listHeight: height))
    }

    @Test func oneDirectoryWithOneFileShowsInFull() {
        let content = Layout.contentHeight(groupCount: 1, rowCount: 1, rowHeight: Self.medium)
        let height = Self.listHeight(content: content)
        #expect(content == Layout.firstHeaderGap + Layout.captionHeight + Self.medium + Layout.bottomPadding)
        #expect(height == content)
        #expect(!Layout.overflows(contentHeight: content, listHeight: height))
    }

    /// Only the rows grow with the sidebar size; captions, gaps and padding stay put.
    @Test(arguments: [StagingTrayLayoutTests.small, StagingTrayLayoutTests.medium, StagingTrayLayoutTests.large])
    func eachFileAddsOneRowHeight(row: CGFloat) {
        let content = Layout.contentHeight(groupCount: 1, rowCount: 2, rowHeight: row)
        #expect(content == Layout.firstHeaderGap + Layout.captionHeight + 2 * row + Layout.bottomPadding)
    }

    @Test func severalDirectoriesUnderTheCapShowInFull() {
        let content = Layout.contentHeight(groupCount: 3, rowCount: 3, rowHeight: Self.small)
        let expected =
            Layout.firstHeaderGap + 3 * Layout.captionHeight + 2 * Layout.sectionGap + 3 * Self.small
            + Layout.bottomPadding
        #expect(content == expected)
        #expect(content < Layout.maxListHeight)
        let height = Self.listHeight(content: content, row: Self.small)
        #expect(height == content)
        #expect(!Layout.overflows(contentHeight: content, listHeight: height))
    }

    @Test func contentAtTheCapFitsWithoutAFade() {
        let height = Self.listHeight(content: Layout.maxListHeight)
        #expect(height == Layout.maxListHeight)
        #expect(!Layout.overflows(contentHeight: Layout.maxListHeight, listHeight: height))
    }

    @Test func contentPastTheCapIsCappedAndFades() {
        let content = Layout.contentHeight(groupCount: 4, rowCount: 10, rowHeight: Self.large)
        let height = Self.listHeight(content: content, row: Self.large)
        #expect(height == Layout.maxListHeight)
        #expect(Layout.overflows(contentHeight: content, listHeight: height))
    }

    /// Changes keeps its floor; the staged list takes what is left, and the fade shows
    /// though the content is under the cap.
    @Test func aShortSidebarClampsTheListAndFades() {
        let content: CGFloat = 150
        let sidebar = Layout.trayChrome + Layout.changesFloor + 100
        let height = Self.listHeight(content: content, sidebar: sidebar)
        #expect(content < Layout.maxListHeight)
        #expect(height == 100)
        #expect(Layout.overflows(contentHeight: content, listHeight: height))
    }

    /// Too short for a caption and a row, the list goes, unless it holds the selection:
    /// then that minimum stays and Changes gives way.
    @Test func noRoomShowsNoneWithoutTheSelectionAndTheMinimumWithIt() {
        let content: CGFloat = 150
        let minimum = Layout.firstHeaderGap + Layout.captionHeight + Self.medium
        let sidebar = Layout.trayChrome + Layout.changesFloor + minimum - 1
        #expect(Self.listHeight(content: content, sidebar: sidebar) == 0)
        let held = Self.listHeight(content: content, sidebar: sidebar, holdsSelection: true)
        #expect(held == minimum)
        #expect(Layout.overflows(contentHeight: content, listHeight: held))
    }

    /// The capsule's clearance comes out of the staged list, not the Changes floor.
    @Test func theCapsuleClearanceShortensTheListInAShortSidebar() {
        let sidebar = Layout.trayChrome + Layout.changesFloor + 100
        let height = Self.listHeight(content: 150, sidebar: sidebar, hasCapsule: true)
        #expect(height == 100 - Layout.capsuleClearance)
    }
}
