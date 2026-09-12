import Foundation

/// Fixed-row-height layout math shared by the panes and the overview strip.
struct PaneLayout: Equatable {
    var rowHeight: CGFloat
    var rowCount: Int

    var contentHeight: CGFloat { CGFloat(rowCount) * rowHeight }

    func y(forRow row: Int) -> CGFloat { CGFloat(row) * rowHeight }

    func row(atY y: CGFloat) -> Int {
        min(max(Int(floor(y / rowHeight)), 0), max(rowCount - 1, 0))
    }

    /// Rows intersecting the vertical span `minY..<maxY`. Empty when there are no rows.
    func rows(intersecting minY: CGFloat, _ maxY: CGFloat) -> Range<Int> {
        guard rowCount > 0, maxY > minY else { return 0..<0 }
        let first = max(0, Int(floor(minY / rowHeight)))
        let last = min(rowCount - 1, Int(ceil(maxY / rowHeight)) - 1)
        guard last >= first else { return 0..<0 }
        return first..<(last + 1)
    }
}

/// Expands tabs to spaces for display, keeping a map from original UTF-16 offsets
/// to expanded offsets so highlight ranges can be translated.
enum TabExpander {
    static func expand(_ line: String, tabWidth: Int) -> (text: String, map: [Int]?) {
        guard line.utf16.contains(9) else { return (line, nil) }
        var output = String.UnicodeScalarView()
        var map: [Int] = []
        map.reserveCapacity(line.utf16.count + 1)
        var column = 0
        for scalar in line.unicodeScalars {
            let units = scalar.utf16.count
            for _ in 0..<units { map.append(column) }
            if scalar == "\t" {
                let spaces = tabWidth - (column % tabWidth)
                for _ in 0..<spaces { output.append(" ") }
                column += spaces
            } else {
                output.append(scalar)
                column += units
            }
        }
        map.append(column)
        return (String(output), map)
    }
}
