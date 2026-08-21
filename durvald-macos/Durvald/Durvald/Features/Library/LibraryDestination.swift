//
//  LibraryDestination.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

enum LibraryDestination: String, CaseIterable, Identifiable {
    case songs
    case albums
    case artists
    case playlists
    case history

    var id: Self { self }

    var title: String {
        switch self {
        case .songs: "Músicas"
        case .albums: "Álbuns"
        case .artists: "Artistas"
        case .playlists: "Playlists"
        case .history: "Histórico"
        }
    }

    var icon: String {
        switch self {
        case .songs: "music.note"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .playlists: "music.note.list"
        case .history: "clock.arrow.circlepath"
        }
    }
}
