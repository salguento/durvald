import AppKit
import XCTest
@testable import Durvald

@MainActor
final class ArtworkColorRepositoryTests: XCTestCase {
    private let owner = NSObject()

    func testActualColorCalculationKeepsSRGBAndOpaqueAlpha() async throws {
        let repository = ArtworkColorRepository()
        let sample = try await repository.lowerRegionColor(for: key("red"), image: makeImage(bottom: .red, top: .red))
        XCTAssertEqual(sample, .init(red: 255, green: 0, blue: 0))
        XCTAssertEqual(sample?.color.alphaComponent, 1)
        let blue = try await repository.lowerRegionColor(for: key("blue"), image: makeImage(bottom: .blue, top: .blue))
        XCTAssertEqual(blue, .init(red: 0, green: 0, blue: 255))
    }

    func testSamplesOnlyLowerThirtyFivePercent() async throws {
        let repository = ArtworkColorRepository()
        let sample = try await repository.lowerRegionColor(for: key("portrait"), image: makeImage(bottom: .red, top: .blue))
        XCTAssertEqual(sample, .init(red: 255, green: 0, blue: 0))
    }

    func testConcurrentRequestsShareCalculationAwayFromMainThread() async throws {
        let probe = ColorCalculationProbe()
        let repository = ArtworkColorRepository(calculator: { probe.calculate($0) })
        let request = key("same")
        let image = makeImage()
        let samples = try await withThrowingTaskGroup(of: ArtworkColorRepository.Sample?.self) { group in
            for _ in 0..<20 {
                group.addTask { try await repository.lowerRegionColor(for: request, image: image) }
            }
            var values: [ArtworkColorRepository.Sample?] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(samples.count, 20)
        XCTAssertTrue(samples.allSatisfy { $0 == probe.sample })
        XCTAssertEqual(probe.count, 1)
        XCTAssertFalse(probe.usedMainThread)
    }

    func testArtworkPixelBucketAndCoreInvalidateIdentity() async throws {
        let probe = ColorCalculationProbe()
        let repository = ArtworkColorRepository(calculator: { probe.calculate($0) })
        let image = makeImage()
        _ = try await repository.lowerRegionColor(for: key("original"), image: image)
        _ = try await repository.lowerRegionColor(for: key("replacement"), image: image)
        _ = try await repository.lowerRegionColor(for: key("original", pixels: 512), image: image)
        let otherOwner = NSObject()
        _ = try await repository.lowerRegionColor(for: .init(coreID: ObjectIdentifier(otherOwner), artworkID: "original", pixelSize: 1024), image: image)
        _ = try await repository.lowerRegionColor(for: key("original"), image: image)
        XCTAssertEqual(probe.count, 4)
    }

    func testCacheIsBoundedAndPromotesRecentColors() async throws {
        let probe = ColorCalculationProbe()
        let repository = ArtworkColorRepository(cacheCountLimit: 2, calculator: { probe.calculate($0) })
        let image = makeImage()
        for id in ["A", "B", "A", "C", "A"] {
            _ = try await repository.lowerRegionColor(for: key(id), image: image)
        }
        XCTAssertEqual(probe.count, 3)
        _ = try await repository.lowerRegionColor(for: key("B"), image: image)
        XCTAssertEqual(probe.count, 4)
    }

    func testMissingColorIsNegativelyCached() async throws {
        let probe = ColorCalculationProbe(sample: nil)
        let repository = ArtworkColorRepository(calculator: { probe.calculate($0) })
        let image = makeImage()
        let first = try await repository.lowerRegionColor(for: key("missing"), image: image)
        let second = try await repository.lowerRegionColor(for: key("missing"), image: image)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(probe.count, 1)
    }

    func testCancelledRequestDoesNotCalculateOrPopulateCache() async throws {
        let probe = ColorCalculationProbe()
        let repository = ArtworkColorRepository(calculator: { probe.calculate($0) })
        let image = makeImage()
        let request = key("cancelled")
        let task = Task { try await repository.lowerRegionColor(for: request, image: image) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request returned a color") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(probe.count, 0)
        _ = try await repository.lowerRegionColor(for: request, image: image)
        XCTAssertEqual(probe.count, 1)
    }

    private func key(_ artworkID: String, pixels: Int = 1024) -> ArtworkColorRepository.Request {
        .init(coreID: ObjectIdentifier(owner), artworkID: artworkID, pixelSize: pixels)
    }

    private func makeImage(bottom: NSColor = .red, top: NSColor = .blue) -> CGImage {
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(top.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(bottom.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 35))
        return context.makeImage()!
    }
}

private final class ColorCalculationProbe: @unchecked Sendable {
    let sample: ArtworkColorRepository.Sample?
    private let lock = NSLock()
    private var calls = 0
    private var mainThread = false
    var count: Int { lock.withLock { calls } }
    var usedMainThread: Bool { lock.withLock { mainThread } }

    init(sample: ArtworkColorRepository.Sample? = .init(red: 12, green: 34, blue: 56)) { self.sample = sample }

    func calculate(_ image: CGImage) -> ArtworkColorRepository.Sample? {
        lock.withLock { calls += 1; mainThread = mainThread || Thread.isMainThread }
        return sample
    }
}
