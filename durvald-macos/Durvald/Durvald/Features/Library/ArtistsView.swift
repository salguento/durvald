//
//  ArtistsView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct ArtistsView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    let onSelectArtist: (Artist) -> Void

    var body: some View {
        List(store.artists, id: \.id) { artist in
            Button {
                onSelectArtist(artist)
            } label: {
                Text(artist.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Abrir artista \(artist.name)")
            .accessibilityIdentifier("artist.\(artist.id)")
        }
    }
}
