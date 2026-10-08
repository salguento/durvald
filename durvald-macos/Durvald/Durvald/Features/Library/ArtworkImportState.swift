import AppKit
import Observation

@MainActor
@Observable
final class ArtworkImportState {
    private(set) var preview: NSImage?
    private(set) var originalBase64: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var revision: UInt64 = 0
    private(set) var hasSelection = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    func select(_ url: URL, maximumPixelSize: Int, includeOriginalBytes: Bool) {
        hasSelection = true
        start {
            try await FileImportService.shared.artwork(from: url, maximumPixelSize: maximumPixelSize, includeOriginalBytes: includeOriginalBytes)
        }
    }

    func loadExisting(_ base64: String?, maximumPixelSize: Int) {
        guard !hasSelection, preview == nil, !isLoading, let base64, !base64.isEmpty else { return }
        start(reportsErrors: false) {
            try await FileImportService.shared.artwork(base64: base64, maximumPixelSize: maximumPixelSize)
        }
    }

    @discardableResult
    func start(reportsErrors: Bool = true, load: @escaping @Sendable () async throws -> ImportedArtwork) -> Task<Void, Never> {
        cancel()
        let request = generation
        errorMessage = nil
        isLoading = true
        let loading = Task {
            do {
                let result = try await load()
                guard !Task.isCancelled, generation == request else { return }
                preview = NSImage(cgImage: result.preview, size: .zero)
                originalBase64 = result.originalBase64
                revision &+= 1
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                if reportsErrors, !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            guard generation == request else { return }
            isLoading = false
            task = nil
        }
        task = loading
        return loading
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }

    func reset() {
        cancel()
        preview = nil
        originalBase64 = nil
        errorMessage = nil
        hasSelection = false
    }
}
