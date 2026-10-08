import Foundation

/// One completed snapshot and one shared worker per entity, owned by the store.
@MainActor
final class CatalogPageCache<Item> {
    private var snapshot: [Item]?
    private var pending: Task<[Item], Error>?
    private var generation = UUID()
    private var pendingID: UUID?

    func invalidate() {
        generation = UUID()
        snapshot = nil
        pending?.cancel()
        pending = nil
        pendingID = nil
    }

    func load(page: @escaping @Sendable (UInt64) async throws -> ([Item], UInt64?)) async throws -> [Item] {
        try Task.checkCancellation()
        if let snapshot { return snapshot }
        let requestGeneration = generation
        let workerID: UUID
        let worker: Task<[Item], Error>
        if let pending, let pendingID {
            workerID = pendingID
            worker = pending
        } else {
            workerID = UUID()
            pendingID = workerID
            worker = Task.detached(priority: .utility) {
                var items: [Item] = []
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    let (loaded, next) = try await page(offset)
                    items.append(contentsOf: loaded)
                    guard let next else { return items }
                    guard next > offset else {
                        throw NSError(domain: "Durvald.CatalogPageCache", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "O catálogo retornou uma página sem avanço."])
                    }
                    offset = next
                }
            }
            pending = worker
        }
        do {
            let items = try await worker.value
            guard generation == requestGeneration else { throw CancellationError() }
            snapshot = items
            pending = nil
            pendingID = nil
            // Cancelling one screen must not cancel a worker used by others.
            try Task.checkCancellation()
            return items
        } catch {
            if generation == requestGeneration, pendingID == workerID {
                pending = nil
                pendingID = nil
            }
            throw error
        }
    }
}
