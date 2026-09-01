import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    let onNavigate: (LibraryDestination) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sua biblioteca")
                        .font(.title2.bold())

                    Text("Acesse rapidamente todo o conteúdo local.")
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    HomeLibraryCard(
                        title: "Músicas",
                        count: store.tracks.count,
                        systemImage: "music.note",
                        destination: .songs,
                        onNavigate: onNavigate
                    )

                    HomeLibraryCard(
                        title: "Álbuns",
                        count: store.releases.count,
                        systemImage: "square.stack",
                        destination: .albums,
                        onNavigate: onNavigate
                    )

                    HomeLibraryCard(
                        title: "Artistas",
                        count: store.artists.count,
                        systemImage: "music.mic",
                        destination: .artists,
                        onNavigate: onNavigate
                    )

                    HomeLibraryCard(
                        title: "Playlists",
                        count: store.playlists.count,
                        systemImage: "music.note.list",
                        destination: .playlists,
                        onNavigate: onNavigate
                    )
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(24)
        }
        .accessibilityIdentifier("home.page")
    }
}

private struct HomeLibraryCard: View {
    let title: String
    let count: Int
    let systemImage: String
    let destination: LibraryDestination
    let onNavigate: (LibraryDestination) -> Void

    var body: some View {
        Button {
            onNavigate(destination)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)

                    Text("\(count) itens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .padding(14)
            .contentShape(Rectangle())
            .background(
                .quaternary,
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) itens")
        .accessibilityHint("Abre \(title.lowercased())")
        .accessibilityIdentifier("home.\(destination.rawValue)")
    }
}

#Preview {
    HomeView(onNavigate: { _ in })
        .environmentObject(DurvaldCoreStore())
}
