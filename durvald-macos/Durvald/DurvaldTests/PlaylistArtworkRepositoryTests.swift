import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Durvald

@MainActor
final class PlaylistArtworkRepositoryTests: XCTestCase {
    func testSharedContentAndSizeBucketsReuseThumbnail() async throws {
        let probe = PlaylistDecodeProbe(image: makeImage())
        let repository = ArtworkRepository(playlistDecoder: { value, pixels in await probe.decode(value, pixels) })
        let sidebarSize = ArtworkRepository.pixelSize(for: 30, scale: 2)
        let listSize = ArtworkRepository.pixelSize(for: 32, scale: 2)
        XCTAssertEqual(sidebarSize, listSize)
        let first = try await repository.playlistImage(base64: "same-content", pixelSize: sidebarSize)
        let reused = try await repository.playlistImage(base64: "same-content", pixelSize: listSize)
        XCTAssertTrue(first === reused)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1)
        _ = try await repository.playlistImage(base64: "edited-content", pixelSize: listSize)
        _ = try await repository.playlistImage(base64: "same-content", pixelSize: 128)
        let afterChanges = await probe.callCount
        XCTAssertEqual(afterChanges, 3)
        XCTAssertEqual(ArtworkRepository.pixelSize(for: 2000, scale: 2), 1024)
    }

    func testConcurrentConsumersShareDecodeAndOneCancellationKeepsOtherAlive() async throws {
        let gate = PlaylistDecodeGate(images: [makeImage()])
        let repository = ArtworkRepository(playlistDecoder: { _, _ in await gate.decode() })
        let first = Task { try await repository.playlistImage(base64: "shared", pixelSize: 64) }
        await gate.waitUntilStarted()
        let second = Task { try await repository.playlistImage(base64: "shared", pixelSize: 64) }
        await waitForConsumers(2, in: repository)
        first.cancel()
        await waitForConsumers(1, in: repository)
        await gate.release()
        do { _ = try await first.value; XCTFail("Cancelled consumer returned an image") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let image = try await second.value
        XCTAssertNotNil(image)
        let calls = await gate.callCount
        XCTAssertEqual(calls, 1)
        let reused = try await repository.playlistImage(base64: "shared", pixelSize: 64)
        XCTAssertTrue(image === reused)
        XCTAssertEqual(repository.activeConsumerCount, 0)
    }

    func testLastConsumerCancellationDoesNotCacheLateResultOrReplaceNewFlight() async throws {
        let gate = PlaylistDecodeGate(images: [makeImage(width: 8), makeImage(width: 16)])
        let repository = ArtworkRepository(playlistDecoder: { _, _ in await gate.decode() })
        let first = Task { try await repository.playlistImage(base64: "shared", pixelSize: 64) }
        await gate.waitUntilStarted()
        first.cancel()
        await waitForConsumers(0, in: repository)
        let replacement = Task { try await repository.playlistImage(base64: "shared", pixelSize: 64) }
        await waitForConsumers(1, in: repository)
        await gate.release()
        do { _ = try await first.value; XCTFail("Cancelled flight returned an image") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let image = try await replacement.value
        XCTAssertEqual(image?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 16)
        let reused = try await repository.playlistImage(base64: "shared", pixelSize: 64)
        XCTAssertTrue(image === reused)
        let calls = await gate.callCount
        XCTAssertEqual(calls, 2)
    }

    func testCountAndByteLimitsEvictOrSkipOversizedImages() async throws {
        let probe = PlaylistDecodeProbe(image: makeImage())
        let limited = ArtworkRepository(cacheCountLimit: 1, playlistDecoder: { value, pixels in await probe.decode(value, pixels) })
        _ = try await limited.playlistImage(base64: "a", pixelSize: 64)
        _ = try await limited.playlistImage(base64: "b", pixelSize: 64)
        _ = try await limited.playlistImage(base64: "a", pixelSize: 64)
        let count = await probe.callCount
        XCTAssertEqual(count, 3)
        let uncached = ArtworkRepository(cacheByteLimit: 1, playlistDecoder: { value, pixels in await probe.decode(value, pixels) })
        _ = try await uncached.playlistImage(base64: "large", pixelSize: 64)
        _ = try await uncached.playlistImage(base64: "large", pixelSize: 64)
        let afterOversized = await probe.callCount
        XCTAssertEqual(afterOversized, 5)
    }

    func testCorruptArtworkIsNegativelyCachedWithoutAffectingOtherContent() async throws {
        let probe = PlaylistDecodeProbe(image: nil)
        let repository = ArtworkRepository(playlistDecoder: { value, pixels in await probe.decode(value, pixels) })
        let first = try await repository.playlistImage(base64: "invalid", pixelSize: 64)
        let second = try await repository.playlistImage(base64: "invalid", pixelSize: 64)
        XCTAssertNil(first)
        XCTAssertNil(second)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 1)
        let production = ArtworkRepository()
        let invalid = try await production.playlistImage(base64: "not base64", pixelSize: 64)
        XCTAssertNil(invalid)
    }

    func testPlaylistAndManagedArtworkHaveIndependentSourcesWithSharedBudget() async throws {
        let bytes = pngBytes()
        let base64 = bytes.base64EncodedString()
        let core = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        core.artworkBytesHandler = { _ in bytes }
        let repository = ArtworkRepository()
        let playlist = try await repository.playlistImage(base64: base64, pixelSize: 64)
        let managed = try await repository.image(for: base64, pixelSize: 64, using: core)
        XCTAssertNotNil(playlist)
        XCTAssertNotNil(managed)
        XCTAssertFalse(playlist === managed)
        let cachedPlaylist = try await repository.playlistImage(base64: base64, pixelSize: 64)
        let cachedManaged = try await repository.image(for: base64, pixelSize: 64, using: core)
        XCTAssertTrue(playlist === cachedPlaylist)
        XCTAssertTrue(managed === cachedManaged)
    }

    private func waitForConsumers(_ count: Int, in repository: ArtworkRepository) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while repository.activeConsumerCount != count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(repository.activeConsumerCount, count)
    }

    private func makeImage(width: Int = 8) -> ImportedArtwork {
        let context = CGContext(data: nil, width: width, height: 8, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ImportedArtwork(preview: context.makeImage()!, originalBase64: nil)
    }

    private func pngBytes() -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, makeImage().preview, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor PlaylistDecodeProbe {
    let image: ImportedArtwork?
    private(set) var callCount = 0
    init(image: ImportedArtwork?) { self.image = image }
    func decode(_ value: String, _ pixels: Int) -> ImportedArtwork? { callCount += 1; return image }
}

private actor PlaylistDecodeGate {
    let images: [ImportedArtwork]
    private(set) var callCount = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var started: CheckedContinuation<Void, Never>?
    init(images: [ImportedArtwork]) { self.images = images }
    func decode() async -> ImportedArtwork {
        let index = callCount
        callCount += 1
        started?.resume()
        started = nil
        if !released { await withCheckedContinuation { waiters.append($0) } }
        return images[min(index, images.count - 1)]
    }
    func waitUntilStarted() async {
        if callCount > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters = [] }
}
