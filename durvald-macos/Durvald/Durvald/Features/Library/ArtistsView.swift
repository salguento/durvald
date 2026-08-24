//
//  ArtistsView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import SwiftUI

struct ArtistsView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    var body: some View {
        List(store.artists, id: \.id) { artist in
            Text(artist.name)
        }
    }
}
