import Foundation
import Testing

@testable import DiffViewer

struct FileSizeTextTests {
    private let locale = Locale(identifier: "en_US")

    @Test func roundsLikeFinder() {
        #expect(FileSizeText.string(300, locale: locale) == "300 bytes")
        #expect(FileSizeText.string(4_000, locale: locale) == "4 kB")
        #expect(FileSizeText.string(1_200_000, locale: locale) == "1.2 MB")
    }
}
