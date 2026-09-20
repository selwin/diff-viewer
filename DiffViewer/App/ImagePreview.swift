import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Preview bitmaps and metadata for both versions of an image file. Stores no source data;
/// a nil side is an absent version.
struct ImagePreview: Sendable {
    struct Decoded: Sendable {
        /// Downsampled to at most `maximumThumbnailDimension` on its long edge.
        let image: CGImage
        /// The file's own dimensions, from its metadata (after EXIF orientation).
        let originalPixelWidth: Int
        let originalPixelHeight: Int
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

    /// Whether the name's extension is an image type (`UTType.image`). Extensionless names are not.
    static func hasImageExtension(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension
        guard !ext.isEmpty else { return false }
        return UTType(filenameExtension: ext)?.conforms(to: .image) ?? false
    }

    /// A nil side is an absent version. Returns nil when neither side decodes.
    /// Throws only `CancellationError`.
    static func decode(old: Data?, new: Data?) async throws -> ImagePreview? {
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

    /// Reads frame 0 only.
    private static func decodeSide(_ data: Data) -> Side {
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
            Decoded(image: image, originalPixelWidth: width, originalPixelHeight: height, byteCount: data.count))
    }
}
