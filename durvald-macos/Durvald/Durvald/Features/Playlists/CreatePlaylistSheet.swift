import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CreatePlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    @State private var title: String
    @State private var playlistDescription: String
    @State private var artworkImport = ArtworkImportState()
    @State private var isChoosingArtwork = false
    @State private var isSaving = false
    @State private var imageError: String?

    private let playlist: Playlist?
    let onSave: (String, String, String?) async -> Bool

    init(
        playlist: Playlist? = nil,
        onSave: @escaping (String, String, String?) async -> Bool
    ) {
        self.playlist = playlist
        self.onSave = onSave
        _title = State(initialValue: playlist?.name ?? "")
        _playlistDescription = State(initialValue: playlist?.description ?? "")
    }

    private enum Field {
        case title
        case description
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(playlist == nil ? "Nova playlist" : "Editar playlist")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .center)

            artworkPicker

            VStack(spacing: 12) {
                TextField("Título da playlist", text: $title)
                    .focused($focusedField, equals: .title)
                    .accessibilityIdentifier("playlist.new.title")

                TextField("Descrição (opcional)", text: $playlistDescription)
                    .focused($focusedField, equals: .description)
                    .accessibilityIdentifier("playlist.new.description")
            }

            HStack(spacing: 12) {
                Button("Cancelar", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)

                Spacer()

                Button(playlist == nil ? "Criar" : "Salvar") {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        guard await onSave(
                            normalizedTitle,
                            playlistDescription,
                            artworkImport.originalBase64 ?? playlist?.artworkId
                        ) else { return }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(normalizedTitle.isEmpty || isSaving || artworkImport.isLoading)
                .accessibilityIdentifier("playlist.new.create")
            }
        }
        .padding(24)
        .frame(width: 320)
        .artworkFileImporter(isPresented: $isChoosingArtwork, state: artworkImport, policy: .playlist)
        .alert("Não foi possível abrir a imagem", isPresented: Binding(
            get: { imageError != nil },
            set: { if !$0 { imageError = nil } }
        )) {
            Button("OK") { imageError = nil }
        } message: {
            Text(imageError ?? "")
        }
        .onAppear {
            focusedField = .title
            artworkImport.loadExisting(playlist?.artworkId, maximumPixelSize: 512)
        }
        .onDisappear { artworkImport.cancel() }
        .onChange(of: artworkImport.errorMessage) { _, message in imageError = message }
    }

    private var artworkPicker: some View {
        Button {
            isChoosingArtwork = true
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)

                if let artwork = artworkImport.preview {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 156, height: 156)
                        .clipShape(.rect(cornerRadius: 12))

                    Text("Alterar imagem")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 30))
                        Text("Selecionar imagem")
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay { if artworkImport.isLoading { ProgressView() } }
            .frame(width: 156, height: 156)
            .artworkGlassBorder(size: 156)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(artworkImport.preview == nil ? "Selecionar imagem" : "Alterar imagem")
        .accessibilityIdentifier("playlist.new.artwork")
    }


}
