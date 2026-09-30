import Foundation
import Testing

@testable import DiffViewer

@Suite struct PreviewDimensionTextTests {
    struct Case: CustomTestStringConvertible {
        let name: String
        let value: CGFloat
        let format: ImagePreview.Format
        let locale: String
        let expected: String

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "raster sizes are whole pixels", value: 200, format: .raster, locale: "en_US", expected: "200"),
        Case(name: "a whole SVG size has no decimals", value: 200, format: .svg, locale: "en_US", expected: "200"),
        Case(name: "an SVG size keeps a decimal", value: 10.5, format: .svg, locale: "en_US", expected: "10.5"),
        Case(name: "an SVG size keeps a small decimal", value: 0.1, format: .svg, locale: "en_US", expected: "0.1"),
        // A hairline the decoder accepts must never read as zero.
        Case(name: "a tiny SVG size keeps its digit", value: 0.001, format: .svg, locale: "en_US", expected: "0.001"),
        Case(
            name: "a tiny SVG size keeps two significant digits", value: 0.00123, format: .svg, locale: "en_US",
            expected: "0.0012"),
        Case(name: "SVG decimals follow the locale", value: 10.5, format: .svg, locale: "de_DE", expected: "10,5"),
    ]

    @Test(arguments: cases) func aDimensionIsFormattedForItsFormatAndLocale(_ testCase: Case) {
        let text = PreviewDimensionText.string(
            testCase.value, format: testCase.format, locale: Locale(identifier: testCase.locale))
        #expect(text == testCase.expected)
    }
}
