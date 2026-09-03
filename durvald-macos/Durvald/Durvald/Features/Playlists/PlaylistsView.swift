//
//  PlaylistsView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct PlaylistsView: View {
    @Environment(DurvaldCoreStore.self) private var store

    var body: some View {
        List(store.playlists, id: \.id) { playlist in
            VStack(alignment: .leading) {
                Text(playlist.name)
                Text("\(playlist.trackCount) músicas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
