import AppKit

@MainActor
final class ArtworkRepository {
    static let shared = ArtworkRepository()

    private let cache = NSCache<NSString, NSImage>()

    private struct SendableCore: @unchecked Sendable {
        let value: DurvaldCore
    }

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 128 * 1024 * 1024
    }

    func cachedImage(for artworkID: String) -> NSImage? {
        cache.object(forKey: artworkID as NSString)
    }

    func image(
        for artworkID: String,
        using core: DurvaldCore
    ) async throws -> NSImage? {
        if let cached = cachedImage(for: artworkID) {
            return cached
        }

        let sendableCore = SendableCore(value: core)
        let bytes = try await Task.detached(priority: .utility) {
            try sendableCore.value.artworkBytes(artworkId: artworkID)
        }.value

        guard
            let bytes,
            let image = NSImage(data: bytes)
        else {
            return nil
        }

        cache.setObject(
            image,
            forKey: artworkID as NSString,
            cost: bytes.count
        )

        return image
    }
}
