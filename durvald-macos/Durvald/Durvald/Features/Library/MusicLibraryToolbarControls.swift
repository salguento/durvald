import AppKit
import SwiftUI

struct MusicLibraryToolbarControls: View {
    @Binding var searchText: String
    @State private var isSearchFocused = false
    @State private var searchFocusRequest = -1
    @Environment(\.openWindow) private var openWindow
    @AppStorage("library.music.onlyFavorites") private var onlyFavorites = false
    @AppStorage("library.music.sort") private var sort: MusicLibrarySort = .title
    @AppStorage("library.music.sortAscending") private var sortAscending = true
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true

    var body: some View {
        HStack(spacing: 12) {
            musicSearchField
            viewOptionsMenu
        }
    }

    private var viewOptionsMenu: some View {
        Menu {
            Picker("Mostrar", selection: $onlyFavorites) {
                Text("Todas as músicas").tag(false)
                Text("Somente favoritas").tag(true)
            }
            .pickerStyle(.inline)
            Divider()
            Menu("Opções de ordenação") {
                Picker("Ordenar por", selection: $sort) {
                    ForEach(MusicLibrarySort.allCases.filter { ratingsEnabled || $0 != .rating }) { option in
                        Text(option.label).tag(option).disabled(!option.isAvailable)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Direção", selection: $sortAscending) {
                    Text("Crescente").tag(true)
                    Text("Decrescente").tag(false)
                }
                .pickerStyle(.inline)
            }
            Divider()
            Button("Mostrar opções de visualização") { openWindow(id: "music-view-options") }
        } label: {
            ZStack {
                Color.clear
                Image(systemName: "line.3.horizontal.decrease")
            }
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 36, height: 36)
        .contentShape(Circle())
        .clipShape(Circle())
        .glassEffect(.regular, in: .circle)
        .help("Opções de visualização")
        .accessibilityLabel("Opções de visualização")
        .accessibilityIdentifier("library.viewOptions")
    }

    private var musicSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            ToolbarSearchTextField(
                text: $searchText,
                isFocused: $isSearchFocused,
                isPresented: true,
                focusRequest: searchFocusRequest,
                placeholder: "Pesquisar músicas",
                accessibilityLabel: "Pesquisar músicas",
                accessibilityIdentifier: "library.search.field"
            )
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpar pesquisa")
                .accessibilityIdentifier("library.search.clear")
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 120, idealWidth: 220, maxWidth: 220, minHeight: 36, maxHeight: 36)
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay {
            if isSearchFocused {
                Capsule()
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Capsule())
        .simultaneousGesture(TapGesture().onEnded {
            if !isSearchFocused { searchFocusRequest += 1 }
        })
        .accessibilityIdentifier("library.search.container")
    }

}

struct MusicLibraryViewOptions: View {
    @AppStorage("library.music.sort") private var sort: MusicLibrarySort = .title
    @AppStorage("library.music.columnLayout") private var savedColumnLayout = ""
    @AppStorage("library.music.artworkSizePosition") private var artworkSizePosition = 0.0
    @AppStorage("library.music.groupArtwork") private var groupArtwork = false
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true

    private var artworkSize: Double {
        let position = min(2, max(0, artworkSizePosition.rounded()))
        return (32 + position * 8) * (groupArtwork ? 3 : 1)
    }

    private var layout: MusicLibraryColumnLayout {
        get {
            guard let data = savedColumnLayout.data(using: .utf8),
                  var value = try? JSONDecoder().decode(MusicLibraryColumnLayout.self, from: data) else {
                return MusicLibraryColumnLayout()
            }
            let missing = MusicLibraryColumn.allCases.filter { !value.order.contains($0) }
            value.order += missing
            value.hidden.formUnion(missing)
            return value
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let value = String(data: data, encoding: .utf8) else { return }
            savedColumnLayout = value
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Ordenar por", selection: $sort) {
                    ForEach(MusicLibrarySort.allCases.filter { $0.isAvailable && (ratingsEnabled || $0 != .rating) }) {
                        Text($0.label).tag($0)
                    }
                }
                columnToggle(.artwork, label: "Mostrar capas")
                Toggle("Agrupar capas de álbuns consecutivos", isOn: $groupArtwork)
                    .disabled(layout.hidden.contains(.artwork))
                VStack(alignment: .leading) {
                    Text("Tamanho da capa")
                    Slider(value: $artworkSizePosition, in: 0...2, step: 1)
                        .accessibilityValue("\(Int(artworkSize)) pontos")
                }
                .disabled(layout.hidden.contains(.artwork))
                Divider()
                section("Música", columns: [.album, .artist, .discNumber, .duration, .trackNumber])
                section("Pessoal", columns: ratingsEnabled ? [.favorite, .rating] : [.favorite])
                section("Estatísticas", columns: [.lastPlayed, .plays])
                section("Arquivo", columns: [.bitrate, .kind, .sampleRate, .size])
                Divider()
                Button("Restaurar padrão") {
                    layout = MusicLibraryColumnLayout()
                    artworkSizePosition = 0
                }
            }
            .toggleStyle(.checkbox)
            .padding(20)
        }
        .frame(width: 420, height: 620)
    }

    private func section(_ title: String, columns: [MusicLibraryColumn]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading) {
                ForEach(columns) { columnToggle($0) }
            }
        }
    }

    private func columnToggle(_ column: MusicLibraryColumn, label: String? = nil) -> some View {
        Toggle(label ?? column.label, isOn: Binding(
            get: { !layout.hidden.contains(column) },
            set: { visible in
                var updated = layout
                if visible { updated.hidden.remove(column) }
                else { updated.hidden.insert(column) }
                layout = updated
            }
        ))
    }
}
