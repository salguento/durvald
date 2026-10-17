import Foundation

// Legacy fixture/import constructors accept whole stars. Runtime reads and edits
// always use the exact ratingHalfSteps field; no lossy display projection exists.

extension Track {
    init(id: Int64, title: String, artist: String, artistId: Int64, release: String, releaseId: Int64, trackNumber: UInt8, discNumber: UInt8, durationSeconds: Double, filePath: String, artworkId: String?, bitrate: UInt32?, sampleRate: UInt32?, bitDepth: UInt8?, playCount: UInt64, lastPlayed: String?,
        rating: UInt8?, isFavorite: Bool, isHidden: Bool, suggestLess: Bool) {
        self.init(id: id,
            title: title,
            artist: artist,
            artistId: artistId,
            release: release,
            releaseId: releaseId,
            trackNumber: trackNumber,
            discNumber: discNumber,
            durationSeconds: durationSeconds,
            filePath: filePath,
            artworkId: artworkId,
            bitrate: bitrate,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            playCount: playCount,
            lastPlayed: lastPlayed,
            ratingHalfSteps: rating.map { $0 * 2 },
            isFavorite: isFavorite,
            isHidden: isHidden,
            suggestLess: suggestLess)
    }
}

extension Release {
    init(id: Int64, title: String, artist: String, artistId: Int64, releaseDate: String?, genres: [String], composers: [String], producers: [String], totalTracks: UInt8, totalDiscs: UInt8, durationSeconds: UInt64, artworkId: String?, isFavorite: Bool, isHidden: Bool, suggestLess: Bool,
        rating: UInt8?) {
        self.init(id: id,
            title: title,
            artist: artist,
            artistId: artistId,
            releaseDate: releaseDate,
            genres: genres,
            composers: composers,
            producers: producers,
            totalTracks: totalTracks,
            totalDiscs: totalDiscs,
            durationSeconds: durationSeconds,
            artworkId: artworkId,
            isFavorite: isFavorite,
            isHidden: isHidden,
            suggestLess: suggestLess,
            ratingHalfSteps: rating.map { $0 * 2 })
    }
}

extension LibraryRepairTrack {
    init(id: Int64, title: String, artist: String, release: String, filePath: String,
        rating: UInt8?, isFavorite: Bool, isMissing: Bool) {
        self.init(id: id,
            title: title,
            artist: artist,
            release: release,
            filePath: filePath,
            ratingHalfSteps: rating.map { $0 * 2 },
            isFavorite: isFavorite,
            isMissing: isMissing)
    }
}
