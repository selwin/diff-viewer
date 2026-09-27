import CoreGraphics
import Testing

@testable import DiffViewer

struct SideBySideLayoutTests {
    private static let bounds = CGRect(x: 0, y: 0, width: 1001, height: 700)

    private func layout(headerHeight: CGFloat) -> SideBySideLayout {
        SideBySideLayout(bounds: Self.bounds, overviewWidth: 14, connectorWidth: 24, headerHeight: headerHeight)
    }

    /// Pane content y maps to connector y as `y - clip.minY` only while the connector
    /// shares the scroll views' vertical band exactly.
    @Test(arguments: [0, 24] as [CGFloat])
    func connectorSharesTheScrollViewsBandAndSitsBetweenThem(headerHeight: CGFloat) {
        let frames = layout(headerHeight: headerHeight)
        for scroll in [frames.leftScroll, frames.rightScroll] {
            #expect(frames.connector.minY == scroll.minY)
            #expect(frames.connector.height == scroll.height)
        }
        #expect(frames.connector.height == Self.bounds.height - headerHeight)
        #expect(frames.leftScroll.maxX == frames.connector.minX)
        #expect(frames.connector.maxX == frames.rightScroll.minX)
        #expect(frames.rightScroll.maxX == frames.overview.minX)
    }

    @Test(arguments: [0, 24] as [CGFloat])
    func headerSeparatorSpansOnlyTheHeaderStrip(headerHeight: CGFloat) {
        let frames = layout(headerHeight: headerHeight)
        #expect(frames.headerSeparator.minY == frames.connector.maxY)
        #expect(frames.headerSeparator.height == headerHeight)
        #expect(frames.headerSeparator.width == 1)
        #expect(frames.leftHeader.maxX == frames.headerSeparator.minX)
        #expect(frames.headerSeparator.maxX == frames.rightHeader.minX)
        #expect(frames.rightHeader.maxX == Self.bounds.width)
    }
}
