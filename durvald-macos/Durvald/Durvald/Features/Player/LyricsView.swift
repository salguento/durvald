import SwiftUI

struct LyricsView: View {
    @Environment(DurvaldCoreStore.self) private var store

    let track: Track
    var usesFixedPopoverSize = true

    @State private var lyrics: String?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Divider()

            Group {
                if isLoading {
                    ProgressView("Carregando letra…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let lyrics {
                    ScrollView {
                        Text(lyrics)
                            .font(.body)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                } else {
                    ContentUnavailableView(
                        "Letra não encontrada",
                        systemImage: "quote.bubble",
                        description: Text(errorMessage ?? "Adicione uma tag de letra ou um arquivo .lrc/.txt ao lado da faixa.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .frame(
            width: usesFixedPopoverSize ? 420 : nil,
            height: usesFixedPopoverSize ? 480 : nil
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: track.id) {
            await loadLyrics()
        }
        .accessibilityIdentifier("lyrics.panel")
    }

    private func loadLyrics() async {
        isLoading = true
        errorMessage = nil
        do {
            lyrics = try await store.lyrics(for: track.id)
        } catch {
            lyrics = nil
            errorMessage = "Não foi possível carregar a letra."
        }
        isLoading = false
    }
}
