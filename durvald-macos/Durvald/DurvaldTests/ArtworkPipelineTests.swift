import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Durvald

@MainActor
final class ArtworkPipelineTests: XCTestCase {
    func testAllByteSourcesUseBoundedDecodingAndKeepOriginalOnlyWhenRequested() async throws {
        let bytes = makeBytes()
        let service = FileImportService(access: ScopedImportFileAccess(start: { _ in false }, stop: { _ in }, read: { _ in bytes }))
        let raw = try await service.artwork(data: bytes, maximumPixelSize: 64)
        let inline = try await service.artwork(base64: bytes.base64EncodedString(), maximumPixelSize: 64)
        let file = try await service.artwork(from: URL(fileURLWithPath: "/image.png"), maximumPixelSize: 64, includeOriginalBytes: true)
        for result in [raw, inline, file] {
            XCTAssertEqual(result.preview.width, 64)
            XCTAssertEqual(result.preview.height, 32)
        }
        XCTAssertNil(raw.originalBase64)
        XCTAssertEqual(inline.originalBase64, file.originalBase64)
    }

    func testEditorPreviewSharesInlineCacheAndPreservesOriginalPayload() async throws {
        let bytes = makeBytes()
        let probe = ArtworkPipelineProbe()
        let repository = ArtworkRepository(playlistDecoder: { value, pixels in
            await probe.record()
            return try await FileImportService.shared.artwork(base64: value, maximumPixelSize: pixels)
        })
        let base64 = bytes.base64EncodedString()
        let first = try await repository.image(for: .base64(base64), pixelSize: 64)
        let preview = try await repository.importedArtwork(base64: base64, maximumPixelSize: 64)
        let again = try await repository.playlistImage(base64: base64, pixelSize: 64)
        XCTAssertTrue(first === again)
        XCTAssertEqual(preview.preview.width, 64)
        XCTAssertEqual(preview.originalBase64, base64)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    func testManagedSourceRequiresCoreAndSeparatesCoreIdentities() async throws {
        let repository = ArtworkRepository()
        let unavailable = try await repository.image(for: .managed("portrait"), pixelSize: 64)
        XCTAssertNil(unavailable)
        let first = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let second = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let bytes = makeBytes()
        first.artworkBytesHandler = { _ in bytes }
        second.artworkBytesHandler = { _ in nil }
        let image = try await repository.image(for: .managed("portrait"), pixelSize: 64, using: first)
        let missing = try await repository.image(for: .managed("portrait"), pixelSize: 64, using: second)
        XCTAssertEqual(image?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 64)
        XCTAssertNil(missing)
    }

    func testCorruptPreviewReportsErrorWhileDisplayUsesFallback() async throws {
        let repository = ArtworkRepository()
        let missing = try await repository.image(for: .base64("corrupt"), pixelSize: 64)
        XCTAssertNil(missing)
        do {
            _ = try await repository.importedArtwork(base64: "corrupt", maximumPixelSize: 64)
            XCTFail("Editor preview must reject corrupt bytes")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testPickerFailureAndEmptySelectionPreserveExistingPreview() async throws {
        let state = ArtworkImportState()
        let imported = try await FileImportService.shared.artwork(data: makeBytes(), maximumPixelSize: 32)
        await state.start { imported }.value
        let previous = state.preview
        state.select(.failure(CocoaError(.fileReadNoPermission)), policy: .playlist)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertTrue(previous === state.preview)
        XCTAssertFalse(state.hasSelection)
        state.select(.success([]), policy: .trackMetadata)
        XCTAssertTrue(previous === state.preview)
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(ArtworkImportPolicy.trackMetadata.maximumPixelSize, 1024)
        XCTAssertFalse(ArtworkImportPolicy.trackMetadata.includeOriginalBytes)
        XCTAssertTrue(ArtworkImportPolicy.playlist.includeOriginalBytes)
    }

    private func makeBytes() -> Data {
        let context = CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8, bytesPerRow: 256 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}

private actor ArtworkPipelineProbe {
    private(set) var calls = 0
    func record() { calls += 1 }
}
