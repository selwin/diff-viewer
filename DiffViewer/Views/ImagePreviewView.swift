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
            // Capped at one source pixel per point so small images are never upscaled.
            Image(decorative: decoded.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .background(Checkerboard())
                .frame(
                    maxWidth: CGFloat(decoded.originalPixelWidth),
                    maxHeight: CGFloat(decoded.originalPixelHeight)
                )
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
            return "\(decoded.originalPixelWidth) × \(decoded.originalPixelHeight) · \(size)"
        case let .undecodable(byteCount)?:
            return FileSizeText.string(Int64(byteCount), locale: locale)
        case nil:
            return nil
        }
    }

    private var accessibilityValue: String {
        switch side {
        case let .decoded(decoded)?:
            "\(decoded.originalPixelWidth) by \(decoded.originalPixelHeight) pixels, "
                + FileSizeText.string(Int64(decoded.byteCount), locale: locale)
        case let .undecodable(byteCount)?:
            "Couldn't decode image, \(FileSizeText.string(Int64(byteCount), locale: locale))"
        case nil: absentText
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).foregroundStyle(Color(nsColor: DiffTheme.noticeText))
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
