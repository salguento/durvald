import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CreatePlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    @State private var title: String
    @State private var playlistDescription: String
    @State private var artwork: NSImage?
    @State private var artworkBase64: String?
    @State private var isChoosingArtwork = false
    @State private var imageError: String?

    private let playlist: Playlist?
    let onSave: (String, String, String?) -> Bool

    init(
        playlist: Playlist? = nil,
        onSave: @escaping (String, String, String?) -> Bool
    ) {
        self.playlist = playlist
        self.onSave = onSave
        _title = State(initialValue: playlist?.name ?? "")
        _playlistDescription = State(initialValue: playlist?.description ?? "")
        _artworkBase64 = State(initialValue: playlist?.artworkId)
        _artwork = State(initialValue: Self.decodeArtwork(playlist?.artworkId))
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
                    guard onSave(normalizedTitle, playlistDescription, artworkBase64) else {
                        return
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(normalizedTitle.isEmpty)
                .accessibilityIdentifier("playlist.new.create")
            }
        }
        .padding(24)
        .frame(width: 320)
        .fileImporter(
            isPresented: $isChoosingArtwork,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: loadArtwork
        )
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
        }
    }

    private var artworkPicker: some View {
        Button {
            isChoosingArtwork = true
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)

                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 156, height: 156)
                        .clipShape(.rect(cornerRadius: 12))

                    Text("Alterar imagem")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: .capsule)
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
            .frame(width: 156, height: 156)
            .artworkGlassBorder(size: 156)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(artwork == nil ? "Selecionar imagem" : "Alterar imagem")
        .accessibilityIdentifier("playlist.new.artwork")
    }

    private func loadArtwork(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            let data = try Data(contentsOf: url)
            guard let image = NSImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            artwork = image
            artworkBase64 = data.base64EncodedString()
        } catch {
            imageError = error.localizedDescription
        }
    }

    private static func decodeArtwork(_ value: String?) -> NSImage? {
        guard let value, !value.isEmpty else { return nil }
        let base64: String
        if value.hasPrefix("data:"), let range = value.range(of: "base64,") {
            base64 = String(value[range.upperBound...])
        } else {
            base64 = value
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }
}
