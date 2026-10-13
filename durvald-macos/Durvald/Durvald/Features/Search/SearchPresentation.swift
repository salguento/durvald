import Foundation
import Observation

struct SearchRequest: Equatable {
    let query: String
    var storeID: ObjectIdentifier? = nil
    var coreID: ObjectIdentifier? = nil
    var metadataRevision = 0
    var sourceRevision: UInt64 = 0
    var scope = ""
}

struct SearchTiming {
    let debounce: Duration
    let loadingDelay: Duration
    static let global = Self(debounce: .milliseconds(200), loadingDelay: .milliseconds(200))
    static let music = Self(debounce: .milliseconds(80), loadingDelay: .milliseconds(250))
    static let suggestions = global
    static let retrospective = Self(debounce: .milliseconds(80), loadingDelay: .zero)
}

/// Owns debounce, committed results and publication. Backends remain domain-specific.
@MainActor
@Observable
final class SearchPresentation<Value> {
    private(set) var value: Value?
    private(set) var committedQuery = ""
    private(set) var isPending = false
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var worker: Task<Value, Error>?
    @ObservationIgnored private var indicator: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func cancel() {
        generation = UUID()
        worker?.cancel()
        indicator?.cancel()
        worker = nil
        indicator = nil
        isPending = false
        isSearching = false
    }

    func reset() {
        cancel()
        value = nil
        committedQuery = ""
        errorMessage = nil
        revision &+= 1
    }

    @discardableResult
    func run(_ request: SearchRequest, timing: SearchTiming, allowsEmpty: Bool = false,
             isCurrent: @escaping @MainActor () -> Bool = { true },
             load: @escaping @MainActor (String) async throws -> Value) async -> Bool {
        guard !Task.isCancelled else { return false }
        cancel()
        let token = generation
        guard allowsEmpty || !request.query.isEmpty else { reset(); return false }
        errorMessage = nil
        isPending = true
        isSearching = timing.loadingDelay == .zero
        if timing.loadingDelay != .zero {
            indicator = Task { @MainActor in
                do { try await sleep(timing.loadingDelay) } catch { return }
                guard !Task.isCancelled, generation == token, isCurrent() else { return }
                isSearching = true
            }
        }
        defer {
            if generation == token {
                indicator?.cancel()
                indicator = nil
                worker = nil
                isPending = false
                isSearching = false
            }
        }
        do {
            if timing.debounce != .zero { try await sleep(timing.debounce) }
            guard !Task.isCancelled, generation == token, isCurrent() else { return false }
            let task = Task { @MainActor in try await load(request.query) }
            worker = task
            let loaded = try await withTaskCancellationHandler { try await task.value } onCancel: {
                task.cancel()
                Task { @MainActor in
                    // A cancelled caller may finish after its replacement has already started.
                    guard self.generation == token else { return }
                    self.cancel()
                }
            }
            guard !Task.isCancelled, generation == token, isCurrent() else { return false }
            value = loaded
            committedQuery = request.query
            revision &+= 1
            return true
        } catch {
            guard !Task.isCancelled, generation == token, isCurrent() else { return false }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            return false
        }
    }
}
