import Foundation
import Testing

@testable import DiffViewer

struct DocumentUpdateTests {
    private static let loadA = UUID()
    private static let loadB = UUID()

    private static func identity(_ load: UUID, _ revision: Int) -> ChangesetIdentity {
        ChangesetIdentity(loadID: load, revision: revision)
    }

    struct Case: CustomTestStringConvertible {
        let name: String
        let installed: ChangesetIdentity?
        let incoming: ChangesetIdentity?
        let mode: DocumentUpdate.Mode

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "the same load with a higher revision appends", installed: identity(loadA, 1),
            incoming: identity(loadA, 2), mode: .append),
        // A skipped intermediate revision still appends: the decision is made against
        // what is installed, not against the last publication.
        Case(
            name: "a skipped revision still appends", installed: identity(loadA, 1), incoming: identity(loadA, 7),
            mode: .append),
        Case(
            name: "the same revision replaces", installed: identity(loadA, 2), incoming: identity(loadA, 2),
            mode: .replace),
        Case(
            name: "a lower revision replaces", installed: identity(loadA, 3), incoming: identity(loadA, 2),
            mode: .replace),
        // Load A's revision 1 is installed, B's revision 1 was coalesced away, B's revision 2 arrives.
        Case(
            name: "a different load replaces", installed: identity(loadA, 1), incoming: identity(loadB, 2),
            mode: .replace),
        Case(name: "no installed changeset replaces", installed: nil, incoming: identity(loadA, 1), mode: .replace),
        Case(name: "no incoming changeset replaces", installed: identity(loadA, 1), incoming: nil, mode: .replace),
        Case(name: "a single-file document on both sides replaces", installed: nil, incoming: nil, mode: .replace),
    ]

    @Test(arguments: cases) func theModeFollowsWhatIsInstalled(_ testCase: Case) {
        #expect(DocumentUpdate.mode(installed: testCase.installed, incoming: testCase.incoming) == testCase.mode)
    }

    @Test func aChangesetCarriesItsOwnIdentity() {
        let changeset = ChangesetBuilder.build(results: [], loadID: Self.loadA, revision: 4)
        #expect(changeset.identity == Self.identity(Self.loadA, 4))
        #expect(DocumentUpdate.mode(installed: Self.identity(Self.loadA, 3), incoming: changeset.identity) == .append)
    }
}
