import AppKit

/// Measuring and placing the pickers' labels.
enum PickerViewGeometry {
    /// A truncating label's `intrinsicContentSize` is capped by its current frame; the
    /// cell's size is the text's natural size.
    static func naturalSize(of field: NSTextField) -> NSSize {
        field.cell?.cellSize ?? .zero
    }

    /// The vertical centre of `field`'s capitals, in its (flipped) superview's coordinates.
    static func capCenterY(of field: NSTextField) -> CGFloat {
        field.frame.minY + field.firstBaselineOffsetFromTop - capHeight(of: field) / 2
    }

    /// The y that puts `field`'s capitals centred on `centerY`.
    static func y(centering field: NSTextField, on centerY: CGFloat) -> CGFloat {
        centerY + capHeight(of: field) / 2 - field.firstBaselineOffsetFromTop
    }

    private static func capHeight(of field: NSTextField) -> CGFloat {
        (field.font ?? .systemFont(ofSize: NSFont.systemFontSize)).capHeight
    }

    /// Pixel alignment that never shrinks a label into truncating.
    static let pixelAlignment: AlignmentOptions = [
        .alignMinXNearest, .alignMinYNearest, .alignWidthOutward, .alignHeightOutward,
    ]
}
