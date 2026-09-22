import SwiftUI

/// Old and new versions of an image side by side, replacing the binary placeholder.
struct ImagePreviewView: View {
    let preview: ImagePreview

    var body: some View {
        HStack(spacing: 0) {
            ImageSideView(side: preview.old, title: "Previous version", absentText: "No previous version")
            Rectangle().fill(Color(nsColor: DiffTheme.divider)).frame(width: 1)
            ImageSideView(side: preview.new, title: "Current version", absentText: "Deleted")
        }
        .background(Color(nsColor: DiffTheme.background))
    }
}

/// One pane: the image (or a notice) above a size caption.
private struct ImageSideView: View {
    let side: ImagePreview.Side?
    let title: String
    let absentText: String
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let caption {
                Text(caption)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(caption)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One element per pane: the side's name, then its size or status.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var content: some View {
        switch side {
        case let .decoded(decoded)?:
            // Shown at most at its own size, in its own aspect ratio: a capped bitmap of a
            // huge SVG is drawn larger than its resolution rather than distorted.
            Image(decorative: decoded.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(decoded.displaySize, contentMode: .fit)
                .background(Checkerboard())
                .frame(maxWidth: decoded.displaySize.width, maxHeight: decoded.displaySize.height)
                .padding(16)
        case .undecodable?:
            notice("Couldn't decode image")
        case nil:
            notice(absentText)
        }
    }

    private var caption: String? {
        switch side {
        case let .decoded(decoded)?:
            let size = FileSizeText.string(Int64(decoded.byteCount), locale: locale)
            let (width, height) = dimensions(decoded)
            let unit = decoded.format == .svg ? "pt" : "px"
            return "\(width) × \(height) \(unit) · \(size)"
        case let .undecodable(byteCount)?:
            return FileSizeText.string(Int64(byteCount), locale: locale)
        case nil:
            return nil
        }
    }

    private func dimensions(_ decoded: ImagePreview.Decoded) -> (width: String, height: String) {
        (
            PreviewDimensionText.string(decoded.displaySize.width, format: decoded.format, locale: locale),
            PreviewDimensionText.string(decoded.displaySize.height, format: decoded.format, locale: locale)
        )
    }

    private var accessibilityValue: String {
        switch side {
        case let .decoded(decoded)?:
            let (width, height) = dimensions(decoded)
            // An SVG has no resolution of its own; its size is in points.
            let unit = decoded.format == .svg ? "points" : "pixels"
            return "\(width) by \(height) \(unit), "
                + FileSizeText.string(Int64(decoded.byteCount), locale: locale)
        case let .undecodable(byteCount)?:
            return "Couldn't decode image, \(FileSizeText.string(Int64(byteCount), locale: locale))"
        case nil: return absentText
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).foregroundStyle(Color(nsColor: DiffTheme.noticeText))
    }
}

/// One dimension of a preview's display size. Raster sizes are whole pixels; an SVG's
/// intrinsic size can be fractional, so it keeps up to two decimals and, below 0.01,
/// two significant digits, so no accepted size ever reads as zero.
enum PreviewDimensionText {
    static func string(_ value: CGFloat, format: ImagePreview.Format, locale: Locale) -> String {
        let number = FloatingPointFormatStyle<Double>.number.locale(locale)
        let style =
            switch format {
            case .raster: number.precision(.fractionLength(0))
            case .svg where value < 0.01: number.precision(.significantDigits(1...2))
            case .svg: number.precision(.fractionLength(0...2))
            }
        return Double(value).formatted(style)
    }
}

/// 8pt squares in the theme's checker colours, so transparent regions read as transparent.
private struct Checkerboard: View {
    private let cellSize: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: DiffTheme.checkerLight)))
            var dark = Path()
            for row in 0..<Int((size.height / cellSize).rounded(.up)) {
                for column in stride(from: row % 2, to: Int((size.width / cellSize).rounded(.up)), by: 2) {
                    dark.addRect(
                        CGRect(
                            x: CGFloat(column) * cellSize, y: CGFloat(row) * cellSize, width: cellSize, height: cellSize
                        ))
                }
            }
            context.fill(dark, with: .color(Color(nsColor: DiffTheme.checkerDark)))
        }
    }
}
