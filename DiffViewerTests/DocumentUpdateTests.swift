import Foundation
import Testing

@testable import DiffViewer

struct DocumentUpdateTests {
    private let loadA = UUID()
    private let loadB = UUID()

    private func identity(_ load: UUID, _ revision: Int) -> ChangesetIdentity {
        ChangesetIdentity(loadID: load, revision: revision)
    }

    @Test func sameLoadWithAHigherRevisionAppends() {
        #expect(DocumentUpdate.mode(installed: identity(loadA, 1), incoming: identity(loadA, 2)) == .append)
        // A skipped intermediate revision still appends: the decision is made against
        // what is installed, not against the last publication.
        #expect(DocumentUpdate.mode(installed: identity(loadA, 1), incoming: identity(loadA, 7)) == .append)
    }

    @Test func sameOrLowerRevisionReplaces() {
        #expect(DocumentUpdate.mode(installed: identity(loadA, 2), incoming: identity(loadA, 2)) == .replace)
        #expect(DocumentUpdate.mode(installed: identity(loadA, 3), incoming: identity(loadA, 2)) == .replace)
    }

    @Test func aDifferentLoadReplaces() {
        #expect(DocumentUpdate.mode(installed: identity(loadA, 1), incoming: identity(loadB, 2)) == .replace)
    }

    @Test func aSingleFileDocumentOnEitherSideReplaces() {
        #expect(DocumentUpdate.mode(installed: nil, incoming: identity(loadA, 1)) == .replace)
        #expect(DocumentUpdate.mode(installed: identity(loadA, 1), incoming: nil) == .replace)
        #expect(DocumentUpdate.mode(installed: nil, incoming: nil) == .replace)
    }

    @Test func installingOneLoadThenSkippingAnothersFirstRevisionReplaces() {
        // A revision 1 installed, B revision 1 coalesced away, B revision 2 arrives.
        #expect(DocumentUpdate.mode(installed: identity(loadA, 1), incoming: identity(loadB, 2)) == .replace)
    }

    @Test func aChangesetCarriesItsOwnIdentity() {
        let changeset = ChangesetBuilder.build(results: [], loadID: loadA, revision: 4)
        #expect(changeset.identity == identity(loadA, 4))
        #expect(DocumentUpdate.mode(installed: identity(loadA, 3), incoming: changeset.identity) == .append)
    }
}
