import Foundation
import Testing

@testable import DiffViewer

/// One delivery per burst of updates, carrying the latest value; nothing is delivered
/// twice, and a reset forgets what was delivered.
@MainActor
struct VisibleSectionPublisherTests {
    private let load = UUID()

    private func reference(_ sectionIndex: Int, load: UUID? = nil) -> VisibleSectionReference {
        VisibleSectionReference(loadID: load ?? self.load, sectionIndex: sectionIndex)
    }

    /// A publisher that appends every delivery to `delivered`.
    private func makePublisher() -> (VisibleSectionPublisher, () -> [VisibleSectionReference?]) {
        let publisher = VisibleSectionPublisher()
        var delivered: [VisibleSectionReference?] = []
        publisher.onChange = { delivered.append($0) }
        return (publisher, { delivered })
    }

    @Test func aBurstOfUpdatesDeliversOnceWithTheLatestValue() {
        let (publisher, delivered) = makePublisher()
        #expect(publisher.update(reference(0)) == true)
        #expect(publisher.update(reference(1)) == false)
        #expect(publisher.update(reference(2)) == false)
        #expect(publisher.isDeliveryPending)

        publisher.deliver()
        #expect(delivered() == [reference(2)])
        #expect(!publisher.isDeliveryPending)
    }

    @Test func firstPublicationOfNilIsDelivered() {
        let (publisher, delivered) = makePublisher()
        #expect(publisher.update(nil) == true)
        publisher.deliver()
        #expect(delivered() == [nil])
    }

    @Test func anUnchangedValueAfterDeliveryPublishesNothing() {
        let (publisher, delivered) = makePublisher()
        _ = publisher.update(reference(3))
        publisher.deliver()

        #expect(publisher.update(reference(3)) == false)
        #expect(!publisher.isDeliveryPending)
        publisher.deliver()
        #expect(delivered() == [reference(3)])
    }

    @Test func aBurstThatReturnsToTheDeliveredValuePublishesNothing() {
        let (publisher, delivered) = makePublisher()
        _ = publisher.update(reference(3))
        publisher.deliver()

        #expect(publisher.update(reference(4)) == true)
        #expect(publisher.update(reference(3)) == false)
        publisher.deliver()
        #expect(delivered() == [reference(3)])
    }

    @Test func resetForgetsTheDeliveredValue() {
        let (publisher, delivered) = makePublisher()
        _ = publisher.update(reference(0))
        publisher.deliver()

        publisher.reset()
        #expect(publisher.current == nil)
        #expect(!publisher.isDeliveryPending)

        let replacement = reference(0, load: UUID())
        #expect(publisher.update(replacement) == true)
        publisher.deliver()
        #expect(delivered() == [reference(0), replacement])
    }

    @Test func resetKeepsAPendingDeliveryAndItCarriesTheReplacement() {
        let (publisher, delivered) = makePublisher()
        #expect(publisher.update(reference(0)) == true)

        publisher.reset()
        let replacement = reference(1, load: UUID())
        #expect(publisher.update(replacement) == false)

        publisher.deliver()
        #expect(delivered() == [replacement])
        publisher.deliver()
        #expect(delivered() == [replacement])
    }
}
