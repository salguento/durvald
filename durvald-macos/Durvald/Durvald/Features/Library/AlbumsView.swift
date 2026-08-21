//
//  AlbumsView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct AlbumsView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    var body: some View {
        List(store.releases, id: \.id) { release in
            VStack(alignment: .leading) {
                Text(release.title)
                Text(release.artist).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Álbuns")
    }
}
