import Foundation
import Testing

@testable import DiffViewer

struct ChurnTextTests {
    struct Case: CustomTestStringConvertible {
        let added: Int
        let deleted: Int
        let locale: String
        let expectedAdded: String?
        let expectedDeleted: String?

        var testDescription: String { "\(added)/\(deleted) \(locale)" }
    }

    static let cases = [
        Case(added: 9, deleted: 0, locale: "en_US", expectedAdded: "+9", expectedDeleted: nil),
        Case(added: 0, deleted: 3, locale: "en_US", expectedAdded: nil, expectedDeleted: "−3"),
        Case(added: 0, deleted: 0, locale: "en_US", expectedAdded: nil, expectedDeleted: nil),
        Case(added: 1204, deleted: 12000, locale: "en_US", expectedAdded: "+1,204", expectedDeleted: "−12,000"),
        Case(added: 1204, deleted: 0, locale: "de_DE", expectedAdded: "+1.204", expectedDeleted: nil),
    ]

    @Test(arguments: cases)
    func dropsZeroSidesAndGroupsForTheLocale(_ testCase: Case) {
        let text = ChurnText.lineCounts(
            added: testCase.added, deleted: testCase.deleted, locale: Locale(identifier: testCase.locale))
        #expect(text.added == testCase.expectedAdded)
        #expect(text.deleted == testCase.expectedDeleted)
    }
}
