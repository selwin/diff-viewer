import Foundation
import Testing

@testable import DiffViewer

@Suite struct PreviewDimensionTextTests {
    private let locale = Locale(identifier: "en_US")

    @Test func rasterSizesAreWholePixels() {
        #expect(PreviewDimensionText.string(200, format: .raster, locale: locale) == "200")
    }

    @Test func svgSizesKeepUpToTwoDecimals() {
        #expect(PreviewDimensionText.string(200, format: .svg, locale: locale) == "200")
        #expect(PreviewDimensionText.string(10.5, format: .svg, locale: locale) == "10.5")
        #expect(PreviewDimensionText.string(0.1, format: .svg, locale: locale) == "0.1")
    }

    /// A hairline the decoder accepts must never read as zero.
    @Test func tinySVGSizesKeepSignificantDigits() {
        #expect(PreviewDimensionText.string(0.001, format: .svg, locale: locale) == "0.001")
        #expect(PreviewDimensionText.string(0.00123, format: .svg, locale: locale) == "0.0012")
    }

    @Test func svgDecimalsFollowTheLocale() {
        #expect(PreviewDimensionText.string(10.5, format: .svg, locale: Locale(identifier: "de_DE")) == "10,5")
    }
}
