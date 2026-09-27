import AppKit
import ImageIO

private actor ArtworkLoadGate {
    private var isAvailable = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if isAvailable {
            isAvailable = false
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isAvailable = true
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
final class ArtworkRepository {
    static let shared = ArtworkRepository()

    private struct CachedArtwork {
        let image: NSImage?
        let cost: Int
    }

    private struct Request: Hashable {
        let coreID: ObjectIdentifier
        let artworkID: String
        let pixelSize: Int
    }

    private struct Flight {
        let task: Task<NSImage?, Error>
        var waiters: Set<UUID>
    }

    private var cache: [Request: CachedArtwork] = [:]
    private var cacheRecency: [Request] = []
    private var cacheCost = 0
    private let cacheByteLimit: Int
    private let cacheCountLimit: Int
    private var inFlight: [Request: Flight] = [:]
    // Keep the complete source bytes for at most one artwork at a time. Limiting
    // only this serial decoding queue would still allow every visible cell to
    // read and retain its full-size source while waiting to be decoded.
    private let loadGate = ArtworkLoadGate()
    private let decodingQueue = DispatchQueue(label: "xyz.salguento.durvald.artwork", qos: .userInitiated)

    private struct SendableCore: @unchecked Sendable {
        let value: DurvaldCore
    }

    init(
        cacheByteLimit: Int = 64 * 1024 * 1024,
        cacheCountLimit: Int = 600
    ) {
        self.cacheByteLimit = max(0, cacheByteLimit)
        self.cacheCountLimit = max(0, cacheCountLimit)
    }

    static func pixelSize(for size: CGFloat, scale: CGFloat) -> Int {
        let requested = max(1, min(size * scale, 1024))
        var bucket = 64
        while CGFloat(bucket) < requested { bucket *= 2 }
        return bucket
    }

    func cachedImage(for artworkID: String, pixelSize: Int, using core: DurvaldCore) -> NSImage? {
        let request = Request(coreID: ObjectIdentifier(core), artworkID: artworkID, pixelSize: pixelSize)
        return cachedArtwork(for: request)?.image
    }

    func image(
        for artworkID: String,
        pixelSize: Int,
        using core: DurvaldCore
    ) async throws -> NSImage? {
        let request = Request(coreID: ObjectIdentifier(core), artworkID: artworkID, pixelSize: pixelSize)
        if let cached = cachedArtwork(for: request) { return cached.image }
        let waiterID = UUID()
        if var existing = inFlight[request] {
            existing.waiters.insert(waiterID)
            inFlight[request] = existing
            return try await wait(
                for: existing.task,
                request: request,
                waiterID: waiterID
            )
        }

        let sendableCore = SendableCore(value: core)
        let task = Task { @MainActor () throws -> NSImage? in
            await loadGate.acquire()
            do {
                try Task.checkCancellation()
            } catch {
                await loadGate.release()
                throw error
            }

            // UniFFI exposes file reads as async methods. Starting the call from
            // the main-actor task would still execute synchronous test doubles
            // (and potentially pre-suspension FFI work) on the UI thread.
            let bytes: Data?
            do {
                bytes = try await Task.detached(priority: .userInitiated) {
                    try await sendableCore.value.artworkBytes(artworkId: artworkID)
                }.value
            } catch {
                await loadGate.release()
                throw error
            }
            do {
                try Task.checkCancellation()
            } catch {
                await loadGate.release()
                throw error
            }

            let thumbnail: CGImage? = await withCheckedContinuation { continuation in
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
            await loadGate.release()

            let image = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
            insertCachedArtwork(
                image,
                cost: thumbnail.map { $0.bytesPerRow * $0.height } ?? 0,
                for: request
            )
            return image
        }
        inFlight[request] = Flight(task: task, waiters: [waiterID])
        return try await wait(for: task, request: request, waiterID: waiterID)
    }

    private func wait(
        for task: Task<NSImage?, Error>,
        request: Request,
        waiterID: UUID
    ) async throws -> NSImage? {
        try await withTaskCancellationHandler {
            defer { finishWaiting(for: request, waiterID: waiterID) }
            return try await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishWaiting(for: request, waiterID: waiterID)
            }
        }
    }

    private func finishWaiting(for request: Request, waiterID: UUID) {
        guard var flight = inFlight[request], flight.waiters.remove(waiterID) != nil else {
            return
        }
        if flight.waiters.isEmpty {
            inFlight[request] = nil
            flight.task.cancel()
        } else {
            inFlight[request] = flight
        }
    }

    private func cachedArtwork(for request: Request) -> CachedArtwork? {
        guard let cached = cache[request] else { return nil }
        cacheRecency.removeAll { $0 == request }
        cacheRecency.append(request)
        return cached
    }

    private func insertCachedArtwork(_ image: NSImage?, cost: Int, for request: Request) {
        let boundedCost = max(0, cost)
        guard cacheCountLimit > 0, boundedCost <= cacheByteLimit else { return }

        if let previous = cache.removeValue(forKey: request) {
            cacheCost -= previous.cost
            cacheRecency.removeAll { $0 == request }
        }

        cache[request] = CachedArtwork(image: image, cost: boundedCost)
        cacheRecency.append(request)
        cacheCost += boundedCost

        while cache.count > cacheCountLimit || cacheCost > cacheByteLimit {
            guard let oldest = cacheRecency.first else { break }
            cacheRecency.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                cacheCost -= removed.cost
            }
        }
    }
}
