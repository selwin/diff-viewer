import Foundation
import Testing

@testable import DiffViewer

struct BinaryChurnTextTests {
    private let locale = Locale(identifier: "en_US")

    private func presentation(old: Int64?, new: Int64?) -> BinaryChurnText.Presentation? {
        BinaryChurnText.presentation(for: BinarySizes(oldByteCount: old, newByteCount: new), locale: locale)
    }

    @Test func bothSidesAbsentHaveNoPresentation() {
        #expect(presentation(old: nil, new: nil) == nil)
    }

    struct Case: CustomTestStringConvertible {
        let name: String
        let old: Int64?
        let new: Int64?
        let kind: BinaryChurnText.ChangeKind
        let primaryText: String
        let deltaText: String?
        let helpText: String

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "added shows the signed new size", old: nil, new: 4_500, kind: .added, primaryText: "+4 kB",
            deltaText: nil, helpText: "Added, 4,500 bytes"),
        Case(
            name: "deleted shows the signed old size", old: 4_500, new: nil, kind: .deleted, primaryText: "−4 kB",
            deltaText: nil, helpText: "Deleted, 4,500 bytes"),
        Case(
            name: "grown shows the new size and a positive delta", old: 12_345, new: 12_645, kind: .grown,
            primaryText: "13 kB", deltaText: "+300 bytes", helpText: "12,345 bytes → 12,645 bytes"),
        Case(
            name: "shrunk shows the new size and a negative delta", old: 12_600, new: 12_300, kind: .shrunk,
            primaryText: "12 kB", deltaText: "−300 bytes", helpText: "12,600 bytes → 12,300 bytes"),
        Case(
            name: "the same size shows the size without a delta", old: 12_345, new: 12_345, kind: .sameSize,
            primaryText: "12 kB", deltaText: nil, helpText: "12,345 bytes, size unchanged"),
        Case(
            name: "a zero-byte addition is not spelled out", old: nil, new: 0, kind: .added, primaryText: "+0 bytes",
            deltaText: nil, helpText: "Added, 0 bytes"),
        Case(
            name: "a zero-byte deletion is not spelled out", old: 0, new: nil, kind: .deleted,
            primaryText: "−0 bytes", deltaText: nil, helpText: "Deleted, 0 bytes"),
        Case(
            name: "a one-byte delta is singular", old: 0, new: 1, kind: .grown, primaryText: "1 byte",
            deltaText: "+1 byte", helpText: "0 bytes → 1 byte"),
        Case(
            name: "growth across a unit boundary uses the larger unit", old: 999_000, new: 1_200_000, kind: .grown,
            primaryText: "1.2 MB", deltaText: "+201 kB", helpText: "999,000 bytes → 1,200,000 bytes"),
    ]

    @Test(arguments: cases) func aFilePresentsItsSizeChange(_ testCase: Case) {
        let result = presentation(old: testCase.old, new: testCase.new)
        #expect(result?.kind == testCase.kind)
        #expect(result?.primaryText == testCase.primaryText)
        #expect(result?.deltaText == testCase.deltaText)
        #expect(result?.helpText == testCase.helpText)
    }
}
