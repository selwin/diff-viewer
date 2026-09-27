import CoreGraphics

/// Every frame in `SideBySideContainerView`, from its bounds. The container is not
/// flipped: the find headers take the top strip and everything else keeps y = 0. The
/// connector spans exactly the scroll views' vertical band, so a pane content y maps to
/// connector y as `y - clip.minY` whether find is open or closed.
struct SideBySideLayout: Equatable {
    let leftHeader: CGRect
    let rightHeader: CGRect
    /// The 1 pt line between the two headers; zero height while find is closed.
    let headerSeparator: CGRect
    let leftScroll: CGRect
    let connector: CGRect
    let rightScroll: CGRect
    let overview: CGRect

    init(bounds: CGRect, overviewWidth: CGFloat, connectorWidth: CGFloat, headerHeight: CGFloat) {
        let width = bounds.width - overviewWidth
        let leftWidth = floor((width - connectorWidth) / 2)
        let height = max(0, bounds.height - headerHeight)
        leftScroll = CGRect(x: 0, y: 0, width: leftWidth, height: height)
        connector = CGRect(x: leftWidth, y: 0, width: connectorWidth, height: height)
        let rightX = leftWidth + connectorWidth
        rightScroll = CGRect(x: rightX, y: 0, width: width - rightX, height: height)
        overview = CGRect(x: bounds.width - overviewWidth, y: 0, width: overviewWidth, height: height)
        // The headers split the strip above the connector evenly, either side of the line.
        let separatorX = leftWidth + floor((connectorWidth - 1) / 2)
        leftHeader = CGRect(x: 0, y: height, width: separatorX, height: headerHeight)
        headerSeparator = CGRect(x: separatorX, y: height, width: 1, height: headerHeight)
        rightHeader = CGRect(
            x: separatorX + 1, y: height, width: bounds.width - separatorX - 1, height: headerHeight)
    }
}
