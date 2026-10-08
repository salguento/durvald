import AppKit
import ImageIO
import CryptoKit

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

    private enum Source: Hashable {
        case managed(coreID: ObjectIdentifier, artworkID: String)
        // The digest keeps large base64 payloads out of the completed cache.
        case playlist(digest: Data)
    }

    private struct Request: Hashable {
        let source: Source
        let pixelSize: Int
    }

    private struct Flight {
        let id: UUID
        let task: Task<NSImage?, Error>
        var waiters: Set<UUID>
    }

    private var cache: [Request: CachedArtwork] = [:]
    private var cacheRecency: [Request] = []
    private var cacheCost = 0
    private let cacheByteLimit: Int
    private let cacheCountLimit: Int
    private let playlistDecoder: @Sendable (String, Int) async throws -> ImportedArtwork?
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
        cacheCountLimit: Int = 600,
        playlistDecoder: @escaping @Sendable (String, Int) async throws -> ImportedArtwork? = { base64, pixelSize in
            do { return try await FileImportService.shared.artwork(base64: base64, maximumPixelSize: pixelSize) }
            catch is CancellationError { throw CancellationError() }
            catch { return nil }
        }
    ) {
        self.cacheByteLimit = max(0, cacheByteLimit)
        self.cacheCountLimit = max(0, cacheCountLimit)
        self.playlistDecoder = playlistDecoder
    }

    static func pixelSize(for size: CGFloat, scale: CGFloat) -> Int {
        let requested = max(1, min(size * scale, 1024))
        var bucket = 64
        while CGFloat(bucket) < requested { bucket *= 2 }
        return bucket
    }

    func cachedImage(for artworkID: String, pixelSize: Int, using core: DurvaldCore) -> NSImage? {
        let request = Request(source: .managed(coreID: ObjectIdentifier(core), artworkID: artworkID), pixelSize: pixelSize)
        return cachedArtwork(for: request)?.image
    }

    func image(
        for artworkID: String,
        pixelSize: Int,
        using core: DurvaldCore
    ) async throws -> NSImage? {
        try Task.checkCancellation()
        let request = Request(source: .managed(coreID: ObjectIdentifier(core), artworkID: artworkID), pixelSize: pixelSize)
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

        let flightID = UUID()
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

            try Task.checkCancellation()
            guard inFlight[request]?.id == flightID else { throw CancellationError() }
            let image = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
            insertCachedArtwork(
                image,
                cost: thumbnail.map { $0.bytesPerRow * $0.height } ?? 0,
                for: request
            )
            return image
        }
        inFlight[request] = Flight(id: flightID, task: task, waiters: [waiterID])
        return try await wait(for: task, request: request, waiterID: waiterID)
    }

    /// All playlist surfaces share the managed-artwork cache budgets and gate,
    /// but their content identity is independent of core-managed artwork IDs.
    func playlistImage(base64: String, pixelSize: Int) async throws -> NSImage? {
        let digest = try await FileImportService.perform {
            // Borrow contiguous UTF-8 while hashing instead of copying the
            // complete base64 string for every visible thumbnail.
            if let digest = base64.utf8.withContiguousStorageIfAvailable({ bytes in
                var hash = SHA256()
                hash.update(bufferPointer: UnsafeRawBufferPointer(bytes))
                return Data(hash.finalize())
            }) { return digest }
            return Data(SHA256.hash(data: Data(base64.utf8)))
        }
        try Task.checkCancellation()
        let request = Request(source: .playlist(digest: digest), pixelSize: pixelSize)
        if let cached = cachedArtwork(for: request) { return cached.image }
        let waiterID = UUID()
        if var flight = inFlight[request] {
            flight.waiters.insert(waiterID)
            inFlight[request] = flight
            return try await wait(for: flight.task, request: request, waiterID: waiterID)
        }
        let flightID = UUID()
        let task = Task { @MainActor () throws -> NSImage? in
            await loadGate.acquire()
            let decoded: ImportedArtwork?
            do {
                try Task.checkCancellation()
                decoded = try await playlistDecoder(base64, pixelSize)
                try Task.checkCancellation()
            } catch {
                await loadGate.release()
                throw error
            }
            await loadGate.release()
            try Task.checkCancellation()
            guard inFlight[request]?.id == flightID else { throw CancellationError() }
            let image = decoded.map { NSImage(cgImage: $0.preview, size: .zero) }
            insertCachedArtwork(image, cost: decoded.map { $0.preview.bytesPerRow * $0.preview.height } ?? 0, for: request)
            return image
        }
        inFlight[request] = Flight(id: flightID, task: task, waiters: [waiterID])
        return try await wait(for: task, request: request, waiterID: waiterID)
    }

    // Useful for inspecting the lifetime of shared requests without their payloads.
    var activeConsumerCount: Int { inFlight.values.reduce(0) { $0 + $1.waiters.count } }

    private func wait(
        for task: Task<NSImage?, Error>,
        request: Request,
        waiterID: UUID
    ) async throws -> NSImage? {
        try await withTaskCancellationHandler {
            defer { finishWaiting(for: request, waiterID: waiterID) }
            let image = try await task.value
            try Task.checkCancellation()
            return image
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
