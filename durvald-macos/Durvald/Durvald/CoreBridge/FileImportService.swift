import Foundation
import ImageIO

struct ImportedArtwork: @unchecked Sendable {
    // CGImage is immutable; all source decoding finishes on the worker.
    let preview: CGImage
    let originalBase64: String?
}

struct ImportedPlaylistPath: Sendable {
    let url: URL
    let canonicalPath: String
}

struct ScopedImportFileAccess: Sendable {
    var start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stop: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
}

/// File reads, ImageIO decoding and path resolution run on a worker. Security
/// scope belongs to that worker, even if its caller cancels during a read.
struct FileImportService: Sendable {
    static let shared = Self()
    var access = ScopedImportFileAccess()

    func artwork(from url: URL, maximumPixelSize: Int, includeOriginalBytes: Bool) async throws -> ImportedArtwork {
        try await Self.perform {
            try withFile(url) { data in
                let preview = try Self.thumbnail(data, maximumPixelSize: maximumPixelSize)
                try Task.checkCancellation()
                return ImportedArtwork(preview: preview, originalBase64: includeOriginalBytes ? data.base64EncodedString() : nil)
            }
        }
    }

    func artwork(data: Data, maximumPixelSize: Int) async throws -> ImportedArtwork {
        try await Self.perform {
            ImportedArtwork(preview: try Self.thumbnail(data, maximumPixelSize: maximumPixelSize), originalBase64: nil)
        }
    }

    func artwork(base64 value: String, maximumPixelSize: Int) async throws -> ImportedArtwork {
        try await Self.perform {
            let base64: String
            if value.hasPrefix("data:"), let range = value.range(of: "base64,") {
                base64 = String(value[range.upperBound...])
            } else { base64 = value }
            guard let data = Data(base64Encoded: base64) else { throw CocoaError(.fileReadCorruptFile) }
            return ImportedArtwork(preview: try Self.thumbnail(data, maximumPixelSize: maximumPixelSize), originalBase64: value)
        }
    }

    func playlistPaths(from url: URL) async throws -> [ImportedPlaylistPath] {
        try await Self.perform {
            try withFile(url) { data in
                try M3U8Playlist(data: data).resolvedURLs(relativeTo: url).map {
                    try Task.checkCancellation()
                    return ImportedPlaylistPath(url: $0, canonicalPath: PlaylistTransferService.canonicalPath($0))
                }
            }
        }
    }

    func pathIndex(_ filePaths: [String]) async throws -> [String: Int] {
        try await Self.perform {
            var result: [String: Int] = [:]
            for (index, path) in filePaths.enumerated() {
                try Task.checkCancellation()
                let canonical = PlaylistTransferService.canonicalPath(URL(fileURLWithPath: path))
                if result[canonical] == nil { result[canonical] = index }
            }
            return result
        }
    }

    private func withFile<Value>(_ url: URL, use: (Data) throws -> Value) throws -> Value {
        try Task.checkCancellation()
        let accessing = access.start(url)
        defer { if accessing { access.stop(url) } }
        let data = try access.read(url)
        try Task.checkCancellation()
        return try use(data)
    }

    private static func thumbnail(_ data: Data, maximumPixelSize: Int) throws -> CGImage {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            try Task.checkCancellation()
            return image
        }
    }

    static func perform<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try work()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: { worker.cancel() }
    }
}
