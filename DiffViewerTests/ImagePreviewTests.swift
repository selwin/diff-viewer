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

    @Test func extensionGate() {
        #expect(ImagePreview.hasImageExtension("logo.png"))
        #expect(ImagePreview.hasImageExtension("Photo.JPG"))
        #expect(ImagePreview.hasImageExtension("a/icon.heic"))
        #expect(!ImagePreview.hasImageExtension("blob.bin"))
        #expect(!ImagePreview.hasImageExtension("README"))
        #expect(!ImagePreview.hasImageExtension("main.swift"))
    }

    @Test func generatedImageIsBinary() throws {
        #expect(DiffEngine.isBinary(try imageData(width: 4, height: 4)))
    }

    @Test func decodesBothSidesWithOriginalSizes() async throws {
        let old = try imageData(width: 7, height: 5)
        let new = try imageData(width: 3, height: 9)
        let preview = try #require(try await ImagePreview.decode(old: old, new: new))
        let oldSide = try #require(decoded(preview.old))
        let newSide = try #require(decoded(preview.new))
        #expect(oldSide.originalPixelWidth == 7 && oldSide.originalPixelHeight == 5)
        #expect(oldSide.byteCount == old.count)
        #expect(newSide.originalPixelWidth == 3 && newSide.originalPixelHeight == 9)
        #expect(newSide.byteCount == new.count)
    }

    @Test func absentSideIsNil() async throws {
        let preview = try #require(try await ImagePreview.decode(old: nil, new: try imageData(width: 2, height: 2)))
        #expect(preview.old == nil)
        #expect(decoded(preview.new) != nil)
    }

    @Test func emptySideIsUndecodable() async throws {
        let preview = try #require(try await ImagePreview.decode(old: Data(), new: try imageData(width: 2, height: 2)))
        #expect(undecodableByteCount(preview.old) == 0)
    }

    @Test func junkSideIsUndecodable() async throws {
        let junk = Data("not an image".utf8)
        let preview = try #require(try await ImagePreview.decode(old: junk, new: try imageData(width: 2, height: 2)))
        #expect(undecodableByteCount(preview.old) == 12)
        #expect(decoded(preview.new) != nil)
    }

    @Test func nothingDecodableIsNil() async throws {
        #expect(try await ImagePreview.decode(old: Data([0, 1, 2]), new: Data([3, 4])) == nil)
        #expect(try await ImagePreview.decode(old: nil, new: nil) == nil)
    }

    @Test func wideImageIsDownsampledButReportsOriginalSize() async throws {
        let preview = try #require(try await ImagePreview.decode(old: nil, new: try imageData(width: 5000, height: 10)))
        let side = try #require(decoded(preview.new))
        #expect(side.image.width <= ImagePreview.maximumThumbnailDimension)
        #expect(side.originalPixelWidth == 5000)
    }

    @Test func exifOrientationTransposesSize() async throws {
        let data = try imageData(width: 7, height: 5, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let preview = try #require(try await ImagePreview.decode(old: nil, new: data))
        let side = try #require(decoded(preview.new))
        #expect(side.originalPixelWidth == 5)
        #expect(side.originalPixelHeight == 7)
        #expect(side.image.width == 5)
        #expect(side.image.height == 7)
    }

    @Test func alreadyCancelledDecodeThrowsCancellationError() async throws {
        let old = try imageData(width: 2, height: 2)
        let new = try imageData(width: 2, height: 2)
        let task = Task { try await ImagePreview.decode(old: old, new: new) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
