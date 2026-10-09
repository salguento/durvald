import Foundation

@MainActor
final class LibraryRepository {
    private let tracks = CatalogPageCache<Track>()
    private let releases = CatalogPageCache<Release>()
    private let files: FileMetadataRepository
    private var revision: UInt64 = 0

    init(files: FileMetadataRepository) { self.files = files }

    func invalidate() {
        revision &+= 1
        tracks.invalidate()
        releases.invalidate()
    }

    func completeTracks(core: DurvaldCore?, visible: [Track], isComplete: Bool) async throws -> [Track] {
        try Task.checkCancellation()
        guard !isComplete, let core else { return visible }
        return try await tracks.load {
            let page = try await core.tracksPage(pageSize: 1_000, offset: $0)
            return (page.items, page.nextOffset)
        }
    }

    func completeReleases(core: DurvaldCore?, visible: [Release]) async throws -> [Release] {
        try Task.checkCancellation()
        guard let core else { return visible }
        return try await releases.load {
            let page = try await core.releasesPage(pageSize: 1_000, offset: $0)
            return (page.items, page.nextOffset)
        }
    }

    func fileSizes(for paths: [String]) async throws -> [String: Int64] {
        let requestedRevision = revision
        let result = try await files.read(paths, revision: requestedRevision)
        try Task.checkCancellation()
        guard requestedRevision == revision else { throw CancellationError() }
        return result
    }
}
