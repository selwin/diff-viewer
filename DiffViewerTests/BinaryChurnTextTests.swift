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

    @Test func addedShowsSignedNewSize() {
        let result = presentation(old: nil, new: 4_500)
        #expect(result?.kind == .added)
        #expect(result?.primaryText == "+4 kB")
        #expect(result?.deltaText == nil)
        #expect(result?.helpText == "Added, 4,500 bytes")
    }

    @Test func deletedShowsSignedOldSize() {
        let result = presentation(old: 4_500, new: nil)
        #expect(result?.kind == .deleted)
        #expect(result?.primaryText == "−4 kB")
        #expect(result?.deltaText == nil)
        #expect(result?.helpText == "Deleted, 4,500 bytes")
    }

    @Test func grownShowsNewSizeAndPositiveDelta() {
        let result = presentation(old: 12_345, new: 12_645)
        #expect(result?.kind == .grown)
        #expect(result?.primaryText == "13 kB")
        #expect(result?.deltaText == "+300 bytes")
        #expect(result?.helpText == "12,345 bytes → 12,645 bytes")
    }

    @Test func shrunkShowsNewSizeAndNegativeDelta() {
        let result = presentation(old: 12_600, new: 12_300)
        #expect(result?.kind == .shrunk)
        #expect(result?.primaryText == "12 kB")
        #expect(result?.deltaText == "−300 bytes")
        #expect(result?.helpText == "12,600 bytes → 12,300 bytes")
    }

    @Test func sameSizeShowsSizeWithoutDelta() {
        let result = presentation(old: 12_345, new: 12_345)
        #expect(result?.kind == .sameSize)
        #expect(result?.primaryText == "12 kB")
        #expect(result?.deltaText == nil)
        #expect(result?.helpText == "12,345 bytes, size unchanged")
    }

    @Test func zeroByteAdditionIsNotSpelledOut() {
        let result = presentation(old: nil, new: 0)
        #expect(result?.kind == .added)
        #expect(result?.primaryText == "+0 bytes")
        #expect(result?.primaryText.contains("Zero") == false)
        #expect(result?.helpText == "Added, 0 bytes")
    }

    @Test func zeroByteDeletionIsNotSpelledOut() {
        let result = presentation(old: 0, new: nil)
        #expect(result?.kind == .deleted)
        #expect(result?.primaryText == "−0 bytes")
        #expect(result?.primaryText.contains("Zero") == false)
        #expect(result?.helpText == "Deleted, 0 bytes")
    }

    @Test func oneByteDeltaIsSingular() {
        let result = presentation(old: 0, new: 1)
        #expect(result?.kind == .grown)
        #expect(result?.primaryText == "1 byte")
        #expect(result?.deltaText == "+1 byte")
        #expect(result?.helpText == "0 bytes → 1 byte")
    }

    @Test func growthAcrossUnitBoundaryUsesLargerUnit() {
        let result = presentation(old: 999_000, new: 1_200_000)
        #expect(result?.kind == .grown)
        #expect(result?.primaryText == "1.2 MB")
        #expect(result?.deltaText == "+201 kB")
        #expect(result?.helpText == "999,000 bytes → 1,200,000 bytes")
    }
}
