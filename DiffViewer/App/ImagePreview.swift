import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Preview bitmaps and metadata for both versions of an image file. Stores no source data;
/// a nil side is an absent version.
struct ImagePreview: Sendable {
    /// Which decoder a side needs: ImageIO for raster images, `NSImage` for SVG.
    enum Format: Sendable {
        case raster
        case svg
    }

    /// One version's bytes and the decoder its name calls for.
    struct Input: Sendable {
        let data: Data
        let format: Format
    }

    struct Decoded: Sendable {
        /// Preview bitmap, capped at `maximumThumbnailDimension` per axis.
        let image: CGImage
        let format: Format
        /// The size to lay the preview out at: pixels (after EXIF orientation) for a
        /// raster image, intrinsic points for an SVG, which has no resolution of its own.
        let displaySize: CGSize
        let byteCount: Int
    }

    enum Side: Sendable {
        case decoded(Decoded)
        /// The version exists, but its data could not be decoded as an image.
        case undecodable(byteCount: Int)
    }

    let old: Side?
    let new: Side?

    static let maximumThumbnailDimension = 4096
    /// Reject unreasonable intrinsic dimensions before sizing the preview.
    static let maximumSVGIntrinsicDimension: CGFloat = 1_000_000

    /// The decoder for the name's extension, or nil when it is not an image type.
    /// Extensionless names are not.
    static func format(for fileName: String) -> Format? {
        let ext = (fileName as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .svg) { return .svg }
        return type.conforms(to: .image) ? .raster : nil
    }

    /// A nil side is an absent version. Returns nil when neither side decodes.
    /// Throws only `CancellationError`.
    static func decode(old: Input?, new: Input?) async throws -> ImagePreview? {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { () throws -> ImagePreview? in
            try Task.checkCancellation()
            let oldSide = old.map(decodeSide)
            try Task.checkCancellation()
            let newSide = new.map(decodeSide)
            guard isDecoded(oldSide) || isDecoded(newSide) else { return nil }
            return ImagePreview(old: oldSide, new: newSide)
        }
        let preview = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        return preview
    }

    private static func isDecoded(_ side: Side?) -> Bool {
        if case .decoded = side { return true }
        return false
    }

    private static func decodeSide(_ input: Input) -> Side {
        switch input.format {
        case .raster: decodeRasterSide(input.data)
        case .svg: decodeSVGSide(input.data)
        }
    }

    /// Reads frame 0 only.
    private static func decodeRasterSide(_ data: Data) -> Side {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            var width = properties[kCGImagePropertyPixelWidth] as? Int,
            var height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return .undecodable(byteCount: data.count) }

        // Orientations 5-8 are quarter turns: the displayed size is transposed.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }

        let thumbnailOptions =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailDimension,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return .undecodable(byteCount: data.count)
        }
        return .decoded(
            Decoded(
                image: image, format: .raster, displaySize: CGSize(width: width, height: height),
                byteCount: data.count))
    }

    /// Rasterises vector data through `NSImage`, which reports the intrinsic size from
    /// `width`/`height` or `viewBox`. Synchronous: the `NSImage` never leaves this call.
    private static func decodeSVGSide(_ data: Data) -> Side {
        guard let image = NSImage(data: data) else { return .undecodable(byteCount: data.count) }
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
            size.width <= maximumSVGIntrinsicDimension, size.height <= maximumSVGIntrinsicDimension
        else { return .undecodable(byteCount: data.count) }

        // Draw at 2x for crispness, less when that would exceed the thumbnail cap.
        let scale = min(2, CGFloat(maximumThumbnailDimension) / max(size.width, size.height))
        let pixelWidth = bitmapDimension(size.width, scale: scale)
        let pixelHeight = bitmapDimension(size.height, scale: scale)
        guard
            let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return .undecodable(byteCount: data.count) }

        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let bitmap = context.makeImage() else { return .undecodable(byteCount: data.count) }
        return .decoded(Decoded(image: bitmap, format: .svg, displaySize: size, byteCount: data.count))
    }

    /// At least one pixel per axis, so an extreme aspect ratio still rasterises.
    private static func bitmapDimension(_ dimension: CGFloat, scale: CGFloat) -> Int {
        min(max(Int((dimension * scale).rounded()), 1), maximumThumbnailDimension)
    }
}
