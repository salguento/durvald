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
        let index: Int
        if let trackID {
            guard let found = tracks.firstIndex(where: { $0.id == trackID }) else { throw SelectionError.missingTrack }
            index = found
        } else { index = tracks.startIndex }
        try await play(Array(tracks[index...]).map { ($0, PlaybackSourceContext.release(id)) }, shuffle: shuffle, core: core, isCurrent: isCurrent, publish: publish)
    }

    func playPlaylist(id: Int64, position: Int, shuffle: Bool?, core: DurvaldCore,
                      isCurrent: () -> Bool, publish: (PlaybackSnapshot) -> Void) async throws {
        let tracks = try await core.playlistTracks(playlistId: id)
        guard tracks.indices.contains(position) else { throw SelectionError.invalidPosition }
        try await play(tracks.enumerated().dropFirst(position).map { ($0.element, PlaybackSourceContext.playlist(id, position: $0.offset)) }, shuffle: shuffle, core: core, isCurrent: isCurrent, publish: publish)
    }

    func playTracks(_ tracks: [Track], startingAt trackID: Int64?, shuffle: Bool, sourceContext: String = "", core: DurvaldCore,
                    isCurrent: () -> Bool, publish: (PlaybackSnapshot) -> Void) async throws {
        let selected: [Track]
        if let trackID, let index = tracks.firstIndex(where: { $0.id == trackID }) { selected = Array(tracks[index...]) }
        else { selected = tracks }
        try await play(selected.map { ($0, sourceContext) }, shuffle: shuffle, core: core, isCurrent: isCurrent, publish: publish)
    }

    private func play(_ tracks: [(track: Track, origin: String)], shuffle: Bool?, core: DurvaldCore,
                      isCurrent: () -> Bool, publish: (PlaybackSnapshot) -> Void) async throws {
        let selected = shuffle == true ? tracks.shuffled() : tracks
        guard let first = selected.first else { return }
        guard isCurrent() else { throw CancellationError() }
        try await core.clearQueue()
        guard isCurrent() else { throw CancellationError() }
        let snapshot = try await core.playWithContext(trackId: first.track.id, sourceContext: first.origin)
        guard isCurrent() else { throw CancellationError() }
        publish(snapshot)
        for item in selected.dropFirst() {
            guard isCurrent() else { throw CancellationError() }
            try await core.addToQueueWithContext(trackId: item.track.id, sourceContext: item.origin)
        }
        if let shuffle {
            guard isCurrent() else { throw CancellationError() }
            let snapshot = try await core.setShuffleEnabled(enabled: shuffle)
            guard isCurrent() else { throw CancellationError() }
            publish(snapshot)
        }
    }
}
