import Foundation
import SwiftUI

/// Presentation payload, not row identity: playlists/queues can repeat a track.
struct TrackRowModel: Equatable {
    let trackID: Int64?
    let title: String
    let artist: String
    let album: String
    let artworkID: String?
    let durationSeconds: Double?
    let isFavorite: Bool
    let rating: UInt8?

    init(_ track: Track) {
        self.init(trackID: track.id, title: track.title, artist: track.artist,
                  album: track.release, artworkID: track.artworkId,
                  durationSeconds: track.durationSeconds, isFavorite: track.isFavorite, rating: track.ratingHalfSteps)
    }

    init(trackID: Int64?, title: String, artist: String = "", album: String = "",
         artworkID: String? = nil, durationSeconds: Double? = nil,
         isFavorite: Bool = false, rating: UInt8? = nil) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkID = artworkID
        self.durationSeconds = durationSeconds
        self.isFavorite = isFavorite
        self.rating = rating
    }

    var accessibilityLabel: String { artist.isEmpty ? title : "\(title), \(artist)" }
    var enqueueLabel: String { "Adicionar \(title) à fila" }
    static func favoriteLabel(_ favorite: Bool) -> String {
        favorite ? "Desfavoritar faixa" : "Favoritar faixa"
    }

    /// Local rows display zero; external rankings distinguish unknown duration.
    func durationText(unknown: String? = nil) -> String {
        DurationFormatter.text(durationSeconds, unknown: unknown)
    }
}

struct TrackRowText: View {
    let model: TrackRowModel
    var subtitle: String? = nil
    var showsEmptySubtitle = false
    var activeOverride: Bool? = nil
    var inactiveColor: Color? = nil
    var titleURL: URL? = nil
    var spacing: CGFloat? = 2
    var lineLimit: Int? = 1

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let titleURL {
                Link(destination: titleURL) { Text(model.title).foregroundStyle(.primary) }
                    .buttonStyle(.plain)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
            } else if let id = model.trackID {
                Text(model.title)
                    .activeTrackTitle(trackID: id, activeOverride: activeOverride, inactiveColor: inactiveColor)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
            } else {
                Text(model.title).lineLimit(lineLimit).truncationMode(.tail)
            }
            let secondary = subtitle ?? model.artist
            if !secondary.isEmpty || showsEmptySubtitle {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
            }
        }
    }
}

/// Preserve collection context and occurrence position when dispatching play.
enum TrackRowPlayback: Equatable {
    case track(Int64, sourceContext: String = PlaybackSourceContext.library)
    case release(Int64, startingAt: Int64)
    case playlist(Int64, position: Int)

    @MainActor
    func perform(using store: DurvaldCoreStore) async {
        switch self {
        case .track(let id, let context): await store.play(trackID: id, sourceContext: context)
        case .release(let id, let track): await store.playRelease(releaseID: id, startingAt: track)
        case .playlist(let id, let position): await store.playPlaylist(playlistID: id, startingAtPosition: position)
        }
    }
}
