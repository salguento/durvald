import Foundation

/// Queue construction is independent of observable playback publication and seek state.
@MainActor
struct PlaybackCoordinator {
    private enum SelectionError: Error, CustomStringConvertible {
        case emptyRelease, missingTrack, invalidPosition
        var description: String {
            switch self {
            case .emptyRelease: "Este álbum não possui faixas."
            case .missingTrack: "A faixa selecionada não pertence a este álbum."
            case .invalidPosition: "A posição selecionada não pertence a esta playlist."
            }
        }
    }

    func playRelease(id: Int64, startingAt trackID: Int64?, shuffle: Bool?, core: DurvaldCore,
                     isCurrent: () -> Bool, publish: (PlaybackSnapshot) -> Void) async throws {
        let tracks = try await core.releaseTracks(releaseId: id).sorted {
            if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
            if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
            return $0.id < $1.id
        }
        guard !tracks.isEmpty else { throw SelectionError.emptyRelease }
        let index: Int?
        if let trackID {
            guard let found = tracks.firstIndex(where: { $0.id == trackID }) else { throw SelectionError.missingTrack }
            index = found
        } else { index = nil }
        try await play(tracks.map { ($0, PlaybackSourceContext.release(id)) }, startingAt: index, shuffle: shuffle, core: core, isCurrent: isCurrent, publish: publish)
    }

    func playPlaylist(id: Int64, position: Int?, shuffle: Bool?, core: DurvaldCore,
                      isCurrent: () -> Bool, publish: (PlaybackSnapshot) -> Void) async throws {
        let tracks = try await core.playlistTracks(playlistId: id)
        if let position, !tracks.indices.contains(position) { throw SelectionError.invalidPosition }
        try await play(tracks.enumerated().map { ($0.element, PlaybackSourceContext.playlist(id, position: $0.offset)) }, startingAt: position, shuffle: shuffle, core: core, isCurrent: isCurrent, publish: publish)
    }

    func playTracks(_ tracks: [Track], startingAt trackID: Int64?, shuffle: Bool?, sourceContext: String = "", core: DurvaldCore,
                    isCurrent: () -> Bool, publish: (PlaybackSnapshot) -> Void) async throws {
        let index: Int?
        if let trackID {
            guard let found = tracks.firstIndex(where: { $0.id == trackID }) else { throw SelectionError.missingTrack }
            index = found
        } else { index = nil }
        try await play(tracks.map { ($0, sourceContext) }, startingAt: index, shuffle: shuffle,
                       core: core, isCurrent: isCurrent, publish: publish)
    }

    private func play(_ tracks: [(track: Track, origin: String)], startingAt position: Int?, shuffle: Bool?, core: DurvaldCore,
                      isCurrent: () -> Bool, publish: (PlaybackSnapshot) -> Void) async throws {
        guard !tracks.isEmpty else { return }
        guard isCurrent() else { throw CancellationError() }
        let snapshot = try await core.playCollection(trackIds: tracks.map { $0.track.id },
            sourceContexts: tracks.map(\.origin), startingPosition: position.map(UInt64.init), shuffleEnabled: shuffle)
        guard isCurrent() else { throw CancellationError() }
        publish(snapshot)
    }
}
