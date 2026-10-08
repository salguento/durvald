import Foundation

/// Shared by the store's consumers. Serial worker isolation makes overlapping
/// collections reuse completed path reads without blocking the MainActor.
actor FileMetadataRepository {
    private struct Entry {
        let size: Int64
        let expiresAt: ContinuousClock.Instant
    }

    private var cache: CostLimitedLRU<String, Entry>
    private var revision: UInt64?
    private let countLimit: Int
    private let lifetime: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let reader: @Sendable (String) -> Int64

    init(countLimit: Int = 50_000, lifetime: Duration = .seconds(30),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         reader: @escaping @Sendable (String) -> Int64 = { path in
             let attributes = try? FileManager.default.attributesOfItem(atPath: path)
             return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
         }) {
        self.countLimit = countLimit
        self.lifetime = lifetime
        self.now = now
        self.reader = reader
        cache = CostLimitedLRU(byteLimit: Int.max, countLimit: countLimit)
    }

    func read(_ paths: [String], revision requestedRevision: UInt64) throws -> [String: Int64] {
        try Task.checkCancellation()
        // A request queued before invalidation cannot roll the cache backward.
        if let revision, requestedRevision < revision { throw CancellationError() }
        if revision != requestedRevision {
            cache = CostLimitedLRU(byteLimit: Int.max, countLimit: countLimit)
            revision = requestedRevision
        }
        var sizes: [String: Int64] = [:]
        for path in Set(paths) {
            try Task.checkCancellation()
            if let entry = cache.value(for: path), now() < entry.expiresAt {
                sizes[path] = entry.size
                continue
            }
            let size = reader(path)
            try Task.checkCancellation()
            cache.insert(Entry(size: size, expiresAt: now().advanced(by: lifetime)), for: path, cost: 1)
            sizes[path] = size
        }
        return sizes
    }
}
