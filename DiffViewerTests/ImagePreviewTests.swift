import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DiffViewer

@Suite struct ImagePreviewTests {
    private func decoded(_ side: ImagePreview.Side?) -> ImagePreview.Decoded? {
        if case let .decoded(decoded) = side { return decoded }
        return nil
    }

    private func undecodableByteCount(_ side: ImagePreview.Side?) -> Int? {
        if case let .undecodable(byteCount) = side { return byteCount }
        return nil
    }

    private func raster(_ data: Data) -> ImagePreview.Input {
        ImagePreview.Input(data: data, format: .raster)
    }

    /// An SVG document with the given attributes and body, as an `.svg` decode input.
    private func svg(_ attributes: String, body: String = "") -> ImagePreview.Input {
        let markup = "<svg xmlns=\"http://www.w3.org/2000/svg\" \(attributes)>\(body)</svg>"
        return ImagePreview.Input(data: Data(markup.utf8), format: .svg)
    }

    /// RGBA bytes of `image`, redrawn into a known layout so the samples are unambiguous.
    private func pixels(_ image: CGImage) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw PixelReadFailure() }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image.width, image.height, bytes)
    }

    private struct PixelReadFailure: Error {}

    @Test func formatForName() {
        #expect(ImagePreview.format(for: "a/icon.svg") == .svg)
        #expect(ImagePreview.format(for: "icon.SVG") == .svg)
        #expect(ImagePreview.format(for: "logo.png") == .raster)
        #expect(ImagePreview.format(for: "Photo.JPG") == .raster)
        #expect(ImagePreview.format(for: "a/icon.heic") == .raster)
        #expect(ImagePreview.format(for: "blob.bin") == nil)
        #expect(ImagePreview.format(for: "main.swift") == nil)
        #expect(ImagePreview.format(for: "README") == nil)
    }

    @Test func generatedImageIsBinary() throws {
        #expect(DiffEngine.isBinary(try imageData(width: 4, height: 4)))
    }

    @Test func decodesBothSidesWithOriginalSizes() async throws {
        let old = try imageData(width: 7, height: 5)
        let new = try imageData(width: 3, height: 9)
        let preview = try #require(try await ImagePreview.decode(old: raster(old), new: raster(new)))
        let oldSide = try #require(decoded(preview.old))
        let newSide = try #require(decoded(preview.new))
        #expect(oldSide.displaySize == CGSize(width: 7, height: 5))
        #expect(oldSide.format == .raster)
        #expect(oldSide.byteCount == old.count)
        #expect(newSide.displaySize == CGSize(width: 3, height: 9))
        #expect(newSide.byteCount == new.count)
    }

    @Test func absentSideIsNil() async throws {
        let preview = try #require(
            try await ImagePreview.decode(old: nil, new: raster(try imageData(width: 2, height: 2))))
        #expect(preview.old == nil)
        #expect(decoded(preview.new) != nil)
    }

    @Test func emptySideIsUndecodable() async throws {
        let preview = try #require(
            try await ImagePreview.decode(old: raster(Data()), new: raster(try imageData(width: 2, height: 2))))
        #expect(undecodableByteCount(preview.old) == 0)
    }

    @Test func junkSideIsUndecodable() async throws {
        let junk = Data("not an image".utf8)
        let preview = try #require(
            try await ImagePreview.decode(old: raster(junk), new: raster(try imageData(width: 2, height: 2))))
        #expect(undecodableByteCount(preview.old) == 12)
        #expect(decoded(preview.new) != nil)
    }

    @Test func nothingDecodableIsNil() async throws {
        #expect(try await ImagePreview.decode(old: raster(Data([0, 1, 2])), new: raster(Data([3, 4]))) == nil)
        #expect(try await ImagePreview.decode(old: nil, new: nil) == nil)
    }

    @Test func wideImageIsDownsampledButReportsOriginalSize() async throws {
        let preview = try #require(
            try await ImagePreview.decode(old: nil, new: raster(try imageData(width: 5000, height: 10))))
        let side = try #require(decoded(preview.new))
        #expect(side.image.width <= ImagePreview.maximumThumbnailDimension)
        #expect(side.displaySize.width == 5000)
    }

    @Test func exifOrientationTransposesSize() async throws {
        let data = try imageData(width: 7, height: 5, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let preview = try #require(try await ImagePreview.decode(old: nil, new: raster(data)))
        let side = try #require(decoded(preview.new))
        #expect(side.displaySize == CGSize(width: 5, height: 7))
        #expect(side.image.width == 5)
        #expect(side.image.height == 7)
    }

    @Test func alreadyCancelledDecodeThrowsCancellationError() async throws {
        let old = raster(try imageData(width: 2, height: 2))
        let new = raster(try imageData(width: 2, height: 2))
        let task = Task { try await ImagePreview.decode(old: old, new: new) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: SVG

    @Test func decodesSVGWithIntrinsicSize() async throws {
        let preview = try #require(try await ImagePreview.decode(old: nil, new: svg("width=\"40\" height=\"20\"")))
        let side = try #require(decoded(preview.new))
        #expect(side.format == .svg)
        #expect(side.displaySize == CGSize(width: 40, height: 20))
        #expect(side.image.width == 80, "rasterised at 2x")
        #expect(side.image.height == 40)
    }

    @Test func viewBoxOnlySVGUsesViewBoxSize() async throws {
        let preview = try #require(try await ImagePreview.decode(old: nil, new: svg("viewBox=\"0 0 30 12\"")))
        let side = try #require(decoded(preview.new))
        #expect(side.displaySize == CGSize(width: 30, height: 12))
    }

    /// The bitmap must hold the drawing the right way up: the red quarter stays top-left.
    @Test func svgRenderingIsNotBlankOrMirrored() async throws {
        let input = svg(
            "width=\"40\" height=\"20\"", body: "<rect x=\"0\" y=\"0\" width=\"20\" height=\"10\" fill=\"red\"/>")
        let preview = try #require(try await ImagePreview.decode(old: nil, new: input))
        let side = try #require(decoded(preview.new))
        let (width, height, bytes) = try pixels(side.image)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
        #expect(pixel(2, 2) == [255, 0, 0, 255], "red in the top-left quarter")
        #expect(pixel(width - 3, height - 3)[3] == 0, "transparent in the opposite corner")
    }

    @Test func fractionalSVGSizeIsKept() async throws {
        let preview = try #require(try await ImagePreview.decode(old: nil, new: svg("width=\"10.5\" height=\"4\"")))
        let side = try #require(decoded(preview.new))
        #expect(side.displaySize.width == 10.5)
    }

    @Test func extremeAspectRatioPreservesIntrinsicSize() async throws {
        let preview = try #require(try await ImagePreview.decode(old: nil, new: svg("width=\"4000\" height=\"0.1\"")))
        let side = try #require(decoded(preview.new))
        #expect(side.image.height == 1, "a sub-pixel side still rasterises")
        #expect(side.displaySize == CGSize(width: 4000, height: 0.1))
    }

    @Test func hugeSVGIsCapped() async throws {
        let preview = try #require(
            try await ImagePreview.decode(old: nil, new: svg("width=\"10000\" height=\"10000\"")))
        let side = try #require(decoded(preview.new))
        #expect(side.image.width <= ImagePreview.maximumThumbnailDimension)
        #expect(side.displaySize.width == 10000)
    }

    @Test func absurdSVGSizeIsUndecodable() async throws {
        let preview = try await ImagePreview.decode(old: nil, new: svg("width=\"1e12\" height=\"1e12\""))
        #expect(preview == nil)
    }

    @Test func svgJunkIsUndecodable() async throws {
        let junk = ImagePreview.Input(data: Data("not svg".utf8), format: .svg)
        #expect(try await ImagePreview.decode(old: nil, new: junk) == nil)
    }

    @Test func oneValidOneInvalidSVGSide() async throws {
        let junk = ImagePreview.Input(data: Data("not svg".utf8), format: .svg)
        let preview = try #require(
            try await ImagePreview.decode(old: junk, new: svg("width=\"8\" height=\"8\"")))
        #expect(undecodableByteCount(preview.old) == 7)
        #expect(decoded(preview.new)?.format == .svg)
    }

    /// A PNG renamed to an SVG: each side is decoded by its own name's format.
    @Test func mixedFormatsDecodePerSide() async throws {
        let preview = try #require(
            try await ImagePreview.decode(
                old: raster(try imageData(width: 7, height: 5)), new: svg("width=\"40\" height=\"20\"")))
        #expect(decoded(preview.old)?.displaySize == CGSize(width: 7, height: 5))
        #expect(decoded(preview.new)?.displaySize == CGSize(width: 40, height: 20))
    }

    @Test func cancelledSVGDecodeThrowsCancellationError() async throws {
        let input = svg("width=\"40\" height=\"20\"")
        let task = Task { try await ImagePreview.decode(old: nil, new: input) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
