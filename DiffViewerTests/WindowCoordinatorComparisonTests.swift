import Foundation
import Testing

@testable import DiffViewer

private let range = CommitRange(
    baseName: "main", targetName: "feature", mergeBaseSHA: objectID("base"), targetSHA: objectID("tip"))
private let comparisonFiles = [changedFile("c.swift", area: .range(range))]

/// Comparison tabs: tracked for key, visibility and close, but kept out of everything that
/// is per repository.
@MainActor
struct WindowCoordinatorComparisonTests {
    /// Repository A open in `owner`, with a comparison of `range` requested beside it.
    private func requestTab() async -> (h: CoordinatorHarness, a: URL, owner: WindowState) {
        let h = CoordinatorHarness()
        let a = h.repo("A", files: [changedFile("a.swift")])
        await h.client(a).set(rangeFiles: comparisonFiles)
        let owner = h.makeWindow()
        #expect(await h.running())
        await h.openAndSettle(a, into: owner)
        #expect(h.coordinator.openComparison(owner: owner.id, range: range))
        return (h, a, owner)
    }

    /// `requestTab`, with the tab's window attached and its state registered.
    private func openTab() async -> (h: CoordinatorHarness, a: URL, owner: WindowState, tab: WindowState) {
        let (h, a, owner) = await requestTab()
        let tab = h.makeState()
        h.coordinator.windowDidAttach(tab.id, sceneRoot: nil)
        #expect(h.coordinator.registerComparison(tab, token: h.log.createdComparisons[0]))
        return (h, a, owner, tab)
    }

    @Test func tabIsTrackedButNeverIndexedPersistedOrTheSavedActiveRepository() async {
        let (h, a, owner, tab) = await openTab()
        let b = h.repo("B")
        let wb = h.makeWindow()
        await h.openAndSettle(b, into: wb)
        h.coordinator.windowDidBecomeKey(wb.id)
        h.coordinator.windowDidBecomeKey(tab.id)

        #expect(h.coordinator.windows[tab.id] === tab)
        #expect(tab.isKey)
        #expect(h.coordinator.rootIndex == [h.root(a): owner.id, h.root(b): wb.id])
        #expect(h.coordinator.openOrder == [h.root(a), h.root(b)])
        #expect(h.savedRoots == [h.root(a), h.root(b)])
        #expect(h.savedActive == h.root(b), "a comparison tab is never the saved active repository")
        #expect(h.log.tabbed == [PresentationLog.Tab(window: tab.id, origin: owner.id)])
        #expect(await eventually { await tab.files.map(\.path) == comparisonFiles.map(\.path) })
        #expect(!h.coordinator.openComparison(owner: tab.id, range: range), "a tab owns no other tab")
    }

    /// A same-named repository makes the owner's title disambiguate; the tab's must not.
    @Test func otherRepositoriesLeaveTheTabTitleAlone() async {
        let (h, _, owner, tab) = await openTab()
        let other = h.repo("elsewhere/A")
        let wo = h.makeWindow()
        await h.openAndSettle(other, into: wo)
        #expect(owner.title != "A", "the owner's title disambiguated")
        #expect(tab.title == range.title)
        h.coordinator.remove(wo.id)
        #expect(tab.title == range.title)
    }

    @Test func closingTheTabLeavesItsRepositoryOpen() async {
        let (h, a, owner, tab) = await openTab()
        h.coordinator.remove(tab.id)
        #expect(tab.isClosed)
        #expect(h.coordinator.windows.count == 1)
        #expect(h.coordinator.rootIndex == [h.root(a): owner.id])
        #expect(h.coordinator.openOrder == [h.root(a)])
        #expect(h.savedRoots == [h.root(a)])
        await h.open(a, from: nil)
        #expect(h.log.focused.last == owner.id, "the owner still holds its repository")
    }

    @Test func unknownSpentAndRefusedTokensRegisterNothing() async {
        let (h, _, owner, tab) = await openTab()
        let strangers = [h.makeState(), h.makeState()]
        #expect(!h.coordinator.registerComparison(strangers[0], token: ComparisonToken()))
        #expect(!h.coordinator.registerComparison(strangers[1], token: h.log.createdComparisons[0]))
        // A refused registration still consumes its request.
        #expect(h.coordinator.openComparison(owner: owner.id, range: range))
        let closed = h.makeState()
        closed.close()
        #expect(!h.coordinator.registerComparison(closed, token: h.log.createdComparisons[1]))

        #expect(h.coordinator.pendingComparisons.isEmpty)
        #expect(Set(h.coordinator.windows.keys) == [owner.id, tab.id])
        #expect(strangers.allSatisfy { $0.isEmpty })
    }

    /// SwiftUI's task can register before the accessor attaches the tab's `NSWindow`.
    @Test func aTabRegisteredBeforeItsWindowAttachesIsTabbedOnAttach() async {
        let (h, _, owner) = await requestTab()
        let tab = h.makeState()
        h.log.unattached = [tab.id]
        #expect(h.coordinator.registerComparison(tab, token: h.log.createdComparisons[0]))
        #expect(h.log.tabbed.isEmpty)

        h.log.unattached = []
        h.coordinator.windowDidAttach(tab.id, sceneRoot: nil)
        h.coordinator.windowDidAttach(tab.id, sceneRoot: nil)
        #expect(h.log.tabbed == [PresentationLog.Tab(window: tab.id, origin: owner.id)])
        #expect(h.coordinator.registerComparison(tab, token: h.log.createdComparisons[0]), "a rerun task keeps its tab")
    }

    @Test func aTabWhoseOwnerClosedBeforeAttachingStaysOutOfTheGroup() async {
        let (h, _, owner) = await requestTab()
        let tab = h.makeState()
        h.log.unattached = [tab.id]
        #expect(h.coordinator.registerComparison(tab, token: h.log.createdComparisons[0]))
        h.coordinator.remove(owner.id)

        h.log.unattached = []
        h.coordinator.windowDidAttach(tab.id, sceneRoot: nil)
        #expect(h.log.tabbed.isEmpty)
    }

    @Test func ownerClosedBeforeRegistrationRefusesTheTab() async {
        let h = CoordinatorHarness()
        let a = h.repo("A")
        let owner = h.makeWindow()
        await h.openAndSettle(a, into: owner)
        #expect(h.coordinator.openComparison(owner: owner.id, range: range))
        h.coordinator.remove(owner.id)
        #expect(!h.coordinator.openComparison(owner: owner.id, range: range))

        let tab = h.makeState()
        #expect(!h.coordinator.registerComparison(tab, token: h.log.createdComparisons[0]))
        #expect(h.coordinator.windows.isEmpty)
        #expect(tab.isEmpty)
    }

    @Test func repositoryReopenedElsewhereWhilePendingRefusesTheTab() async {
        let h = CoordinatorHarness()
        let a = h.repo("A")
        let w1 = h.makeWindow()
        await h.openAndSettle(a, into: w1)
        #expect(h.coordinator.openComparison(owner: w1.id, range: range))
        h.coordinator.remove(w1.id)
        let w2 = h.makeWindow()
        await h.openAndSettle(a, into: w2)

        let tab = h.makeState()
        #expect(!h.coordinator.registerComparison(tab, token: h.log.createdComparisons[0]))
        #expect(Array(h.coordinator.windows.keys) == [w2.id])
        #expect(h.coordinator.rootIndex == [h.root(a): w2.id])
        #expect(w2.title == "A")
        #expect(h.log.tabbed.isEmpty)
    }
}
