import AppKit
import CryptoKit

actor ArtworkLoadGate {
    private var isAvailable = true
    private var waiters = CircularFIFO<CheckedContinuation<Void, Never>>()
    var waitingCount: Int { waiters.count }

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
        if let waiter = waiters.popFirst() { waiter.resume() }
        else { isAvailable = true }
    }
}

@MainActor
final class ArtworkRepository {
    static let shared = ArtworkRepository()

    private struct CachedArtwork {
        let image: NSImage?
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

    private let cache: CostLimitedLRU<Request, CachedArtwork>
    private let playlistDecoder: @Sendable (String, Int) async throws -> ImportedArtwork?
    private var inFlight: [Request: Flight] = [:]
    // Keep the complete source bytes for at most one artwork at a time. Limiting
    // only decoding would still allow every visible cell to
    // read and retain its full-size source while waiting to be decoded.
    private let loadGate = ArtworkLoadGate()

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
        self.cache = CostLimitedLRU(byteLimit: cacheByteLimit, countLimit: cacheCountLimit)
        self.playlistDecoder = playlistDecoder
    }

    static func pixelSize(for size: CGFloat, scale: CGFloat) -> Int {
        let requested = max(1, min(size * scale, 1024))
        var bucket = 64
        while CGFloat(bucket) < requested { bucket *= 2 }
        return bucket
    }

    func image(for source: ArtworkSource, pixelSize: Int, using core: DurvaldCore? = nil) async throws -> NSImage? {
        try Task.checkCancellation()
        switch source {
        case .managed(let id):
            guard let core else { return nil }
            return try await image(for: id, pixelSize: pixelSize, using: core)
        case .base64(let value):
            return try await playlistImage(base64: value, pixelSize: pixelSize)
        }
    }

    /// Existing editor previews share thumbnail flights and cache with playlist rows.
    func importedArtwork(base64: String, maximumPixelSize: Int) async throws -> ImportedArtwork {
        let image = try await image(for: .base64(base64), pixelSize: maximumPixelSize)
        try Task.checkCancellation()
        guard let preview = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return ImportedArtwork(preview: preview, originalBase64: base64)
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

            let thumbnail: CGImage?
            do {
                if let bytes {
                    thumbnail = try await FileImportService.shared.artwork(data: bytes, maximumPixelSize: pixelSize).preview
                } else { thumbnail = nil }
            } catch is CancellationError {
                await loadGate.release()
                throw CancellationError()
            } catch {
                thumbnail = nil
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
        cache.value(for: request)
    }

    private func insertCachedArtwork(_ image: NSImage?, cost: Int, for request: Request) {
        cache.insert(CachedArtwork(image: image), for: request, cost: cost)
    }
}
