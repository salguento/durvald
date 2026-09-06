import AppKit
import ImageIO

@MainActor
final class ArtworkRepository {
    static let shared = ArtworkRepository()

    private final class CachedArtwork {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }

    private struct Request: Hashable {
        let coreID: ObjectIdentifier
        let artworkID: String
        let pixelSize: Int

        var cacheKey: NSString {
            "\(coreID):\(pixelSize):\(artworkID)" as NSString
        }
    }

    private let cache = NSCache<NSString, CachedArtwork>()
    private var inFlight: [Request: Task<NSImage?, Error>] = [:]
    // Bound disk reads and image decoding even when a fast scroll exposes many
    // new covers. Neither operation runs on the UI thread.
    private let decodingQueue = DispatchQueue(label: "xyz.salguento.durvald.artwork", qos: .userInitiated)

    private struct SendableCore: @unchecked Sendable {
        let value: DurvaldCore
    }

    init() {
        cache.countLimit = 600
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    static func pixelSize(for size: CGFloat, scale: CGFloat) -> Int {
        let requested = max(1, min(size * scale, 2048))
        var bucket = 64
        while CGFloat(bucket) < requested { bucket *= 2 }
        return bucket
    }

    func cachedImage(for artworkID: String, pixelSize: Int, using core: DurvaldCore) -> NSImage? {
        let request = Request(coreID: ObjectIdentifier(core), artworkID: artworkID, pixelSize: pixelSize)
        return cache.object(forKey: request.cacheKey)?.image
    }

    func image(
        for artworkID: String,
        pixelSize: Int,
        using core: DurvaldCore
    ) async throws -> NSImage? {
        let request = Request(coreID: ObjectIdentifier(core), artworkID: artworkID, pixelSize: pixelSize)
        if let cached = cache.object(forKey: request.cacheKey) { return cached.image }
        if let existing = inFlight[request] { return try await existing.value }

        let sendableCore = SendableCore(value: core)
        let task = Task { @MainActor () throws -> NSImage? in
            let bytes = try await sendableCore.value.artworkBytes(artworkId: artworkID)
            let thumbnail: CGImage? = try await withCheckedThrowingContinuation { continuation in
                decodingQueue.async {
                    let thumbnail: CGImage? = autoreleasepool {
                        guard let bytes,
                              let source = CGImageSourceCreateWithData(bytes as CFData, [
                                    kCGImageSourceShouldCache: false
                                  ] as CFDictionary)
                        else { return nil }

                        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                            kCGImageSourceShouldCacheImmediately: true
                        ] as CFDictionary)
                    }
                    continuation.resume(returning: thumbnail)
                }
            }
            let image = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
            cache.setObject(
                CachedArtwork(image),
                forKey: request.cacheKey,
                cost: thumbnail.map { $0.bytesPerRow * $0.height } ?? 0
            )
            return image
        }
        inFlight[request] = task
        defer { inFlight[request] = nil }
        return try await task.value
    }
}
