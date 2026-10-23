import AppKit
import Observation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class TrackInfoCoordinator {
    var trackIDs: [Int64] = []
    var navigationTrackIDs: [Int64] = []
    @ObservationIgnored var classificationNavigation: ((ClassificationKind, Int64) -> Void)?
    @ObservationIgnored var presentWindow: (() -> Void)?
    @ObservationIgnored weak var referenceWindow: NSWindow?
    @ObservationIgnored private var openRequest = UUID()

    var trackID: Int64? { trackIDs.count == 1 ? trackIDs[0] : nil }

    func openAlbum(releaseID: Int64, using store: DurvaldCoreStore) async {
        let request = UUID()
        openRequest = request
        let core = store.core
        let window = NSApp.keyWindow
        let tracks = await store.tracks(forReleaseID: releaseID)
        guard !Task.isCancelled, openRequest == request, store.core === core else { return }
        guard !tracks.isEmpty else {
            if store.errorMessage == nil { store.errorMessage = "Este álbum não possui faixas locais para consultar os metadados." }
            return
        }
        var seen = Set<Int64>()
        let orderedIDs = tracks.map(\.id).filter { seen.insert($0).inserted }
        guard let firstID = orderedIDs.first else { return }
        referenceWindow = window
        trackIDs = [firstID]
        navigationTrackIDs = orderedIDs
        presentWindow?()
    }

    func open(trackID: Int64, navigationTrackIDs: [Int64] = []) {
        openRequest = UUID()
        referenceWindow = NSApp.keyWindow
        self.navigationTrackIDs = navigationTrackIDs
        trackIDs = [trackID]
        presentWindow?()
    }

    func openBatch(trackIDs: Set<Int64>) {
        openRequest = UUID()
        referenceWindow = NSApp.keyWindow
        self.trackIDs = trackIDs.sorted()
        navigationTrackIDs = []
        presentWindow?()
    }
}

struct TrackMetadataDraft: Equatable {
    var title: String
    var artist: String
    var albumArtist: String
    var album: String
    var genre: String
    var year: String
    var trackNumber: String
    var discNumber: String
    var composer: String
    var comment: String

    init(_ value: TrackMetadataEdit) {
        title = value.title
        artist = value.artist
        albumArtist = value.albumArtist
        album = value.album
        genre = value.genre
        year = value.year.map(String.init) ?? ""
        trackNumber = value.trackNumber.map(String.init) ?? ""
        discNumber = value.discNumber.map(String.init) ?? ""
        composer = value.composer
        comment = value.comment
    }

    func metadata() throws -> TrackMetadataEdit {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DraftError.invalid("Título, artista e álbum são obrigatórios.")
        }
        return TrackMetadataEdit(
            title: title, artist: artist, albumArtist: albumArtist, album: album, genre: genre,
            year: try MetadataDraftValidation.number(year, name: "Ano", maximum: 9999),
            trackNumber: try MetadataDraftValidation.number(trackNumber, name: "Faixa", maximum: 255),
            discNumber: try MetadataDraftValidation.number(discNumber, name: "Disco", maximum: 255),
            composer: composer, comment: comment
        )
    }

    enum DraftError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
    }
}

struct TrackInfoSheet: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("metadata.writeChangesToFiles") private var writeChangesToFiles = true
    @AppStorage(RatingPreferences.enabledKey) private var ratingsEnabled = true
    let trackID: Int64
    var navigationTrackIDs: [Int64] = []
    var onSelectTrack: (Int64) -> Void = { _ in }

    @State private var info: TrackInfo?
    @State private var editing = EditingState<TrackMetadataDraft?>(nil)
    private var draft: TrackMetadataDraft? {
        get { editing.value }
        nonmutating set { editing.value = newValue }
    }
    private var isSaving: Bool { editing.isSaving }
    private var errorMessage: String? {
        get { editing.errorMessage }
        nonmutating set { editing.errorMessage = newValue }
    }
    @State private var statusMessage: String?
    @State private var isChoosingArtwork = false
    @State private var artworkImport = ArtworkImportState()

    private enum Tab: String, CaseIterable {
        case details = "Detalhes", artwork = "Capa", lyrics = "Letras", options = "Opções", file = "Arquivo"
        case classification = "Gêneros"
        case personalTags = "Tags"
    }
    @State private var selectedTab: Tab = .details
    @State private var lyrics: String?
    @State private var lyricsLoaded = false

    private struct LoadRequest: Equatable {
        let trackID: Int64
        let coreID: ObjectIdentifier?
    }

    private struct LyricsRequest: Equatable {
        let tab: Tab
        let trackID: Int64?
        let coreID: ObjectIdentifier?
    }

    private let accent = Color.accentColor
    private static let tabPickerMaxWidth: CGFloat = 620 - 28
    private static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 34 / 255, green: 44 / 255, blue: 52 / 255, alpha: 1)
            : .windowBackgroundColor
    })
    private static let headerSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 58 / 255, green: 64 / 255, blue: 69 / 255, alpha: 1)
            : .controlBackgroundColor
    })

    var body: some View {
        content
        .frame(minWidth: 620, idealWidth: 680, maxWidth: .infinity,
               minHeight: 520, idealHeight: 780, maxHeight: .infinity, alignment: .topLeading)
        .font(.body)
        .background(Self.surface)
        .background(WindowTrafficLightsHider())
        .ignoresSafeArea(.container, edges: .top)
        .interactiveDismissDisabled(isSaving || editing.isDirty)
        .artworkFileImporter(isPresented: $isChoosingArtwork, state: artworkImport, policy: .trackMetadata)
        .task(id: LoadRequest(trackID: trackID, coreID: store.core.map(ObjectIdentifier.init))) { artworkImport.reset(); await load() }
        .task(id: store.ratingScaleRevision) {
            guard store.ratingScaleRevision > 0, !store.isChangingRatingScale,
                  let refreshed = try? await store.core?.trackInfo(trackId: trackID), info?.track.id == trackID else { return }
            info?.track.ratingHalfSteps = refreshed.track.ratingHalfSteps
        }
        .onDisappear { artworkImport.cancel() }
        .onChange(of: artworkImport.errorMessage) { _, message in
            if let message { errorMessage = "Não foi possível abrir a imagem: \(message)" }
        }
        .onChange(of: artworkImport.revision) { _, _ in errorMessage = nil }
        .task(id: LyricsRequest(tab: selectedTab, trackID: info?.track.id, coreID: store.core.map(ObjectIdentifier.init))) {
            guard selectedTab == .lyrics, info?.track.id == trackID, !lyricsLoaded else { return }
            let coreID = store.core.map(ObjectIdentifier.init)
            do {
                let value = try await store.lyrics(for: trackID)
                guard !Task.isCancelled, store.core.map(ObjectIdentifier.init) == coreID else { return }
                lyrics = value
                lyricsLoaded = true
            } catch {
                guard !Task.isCancelled, store.core.map(ObjectIdentifier.init) == coreID else { return }
                errorMessage = "Não foi possível carregar a letra: \(error.localizedDescription)"
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 20) {
                tabs
                    .frame(maxWidth: Self.tabPickerMaxWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, -10)
                GeometryReader { viewport in
                    ScrollView {
                        if let info, draft != nil {
                            tabContent(info, availableHeight: viewport.size.height)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        } else if errorMessage == nil {
                            ProgressView("Carregando metadados…")
                                .frame(maxWidth: .infinity, minHeight: 200)
                        }
                    }
                }
                .disabled(isSaving)
                .frame(maxHeight: .infinity)
                if isSaving { ProgressView("Salvando…") }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(accent).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("trackInfo.error")
                }
                if let statusMessage {
                    Text(statusMessage).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("trackInfo.status")
                }
                footer
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ArtworkView(artworkID: info?.track.artworkId, size: 96)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(4)
                .background(accent, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard !isSaving else { return }
                    isChoosingArtwork = true
                }
                .help("Clique duas vezes para alterar a imagem.")
            VStack(alignment: .leading, spacing: 3) {
                Text(draft?.title ?? info?.track.title ?? "Info da faixa")
                    .font(.title3).lineLimit(2)
                Text(draft?.artist ?? info?.track.artist ?? "")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(draft?.album ?? info?.track.release ?? "")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let info {
                Button {
                    Task {
                        await store.setTrackFavorite(trackID: trackID, favorite: !info.track.isFavorite, fallbackTrack: info.track)
                        if let refreshed = try? await store.core?.trackInfo(trackId: trackID) { self.info = refreshed }
                    }
                } label: {
                    Image(systemName: info.track.isFavorite ? "star.fill" : "star")
                        .font(.body).foregroundStyle(accent)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                .accessibilityLabel(info.track.isFavorite ? "Desfavoritar faixa" : "Favoritar faixa")
                .accessibilityIdentifier("trackInfo.favorite")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.headerSurface)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    Text(tab.rawValue)
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .foregroundStyle(selectedTab == tab ? Color.white : Color.primary)
                        .background(selectedTab == tab ? accent : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                .accessibilityIdentifier("trackInfo.tab.\(String(describing: tab))")
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private func tabContent(_ info: TrackInfo, availableHeight: CGFloat) -> some View {
        switch selectedTab {
        case .classification:
            ClassificationSection(target: .track, itemID: trackID)
        case .personalTags:
            PersonalTagSection(selection: PersonalTagSelection(trackIDs: [trackID]))
        case .details:
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                field("Título", \.title)
                field("Artista", \.artist)
                field("Álbum", \.album)
                field("Artista do álbum", \.albumArtist)
                field("Compositor", \.composer)
                field("Gênero", \.genre)
                field("Ano", \.year, width: 90)
                field("Faixa", \.trackNumber, width: 60)
                field("Disco", \.discNumber, width: 60)
                if ratingsEnabled {
                    row("Avaliação") {
                        RatingControl(rating: info.track.ratingHalfSteps, isEditable: true,
                                      accentForeground: accent, identity: .track(trackID), onCommit: updateRating)
                            .accessibilityIdentifier("trackInfo.rating")
                    }
                }
                row("Reproduções") { Text(info.track.playCount.formatted()) }
                field("Comentário", \.comment, multiline: true)
            }
        case .artwork:
            VStack(alignment: .center, spacing: 16) {
                GeometryReader { geometry in
                    let size = max(0, min(geometry.size.width, geometry.size.height))
                    Group {
                        if let artworkPreview = artworkImport.preview {
                            Image(nsImage: artworkPreview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: size, height: size)
                        } else {
                            ArtworkView(artworkID: info.track.artworkId, size: size)
                        }
                    }
                        .overlay { if artworkImport.isLoading { ProgressView() } }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottom) {
                            Button("Alterar imagem") { isChoosingArtwork = true }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .glassEffect(.regular, in: .capsule)
                                .buttonStyle(.plain)
                                .disabled(isSaving)
                                .accessibilityIdentifier("trackInfo.changeArtwork")
                                .padding(8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: Self.tabPickerMaxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, -10)
            }
            .frame(height: max(0, availableHeight - 8))
            .frame(maxWidth: .infinity)
        case .lyrics:
            if !lyricsLoaded {
                ProgressView("Carregando letra…").frame(maxWidth: .infinity)
            } else {
                Text(lyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                     ? lyrics! : "Esta faixa não possui letra disponível.")
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .options:
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Gravar alterações no arquivo", isOn: $writeChangesToFiles)
                    .toggleStyle(.checkbox)
                Text(writeChangesToFiles
                     ? "As tags serão gravadas no arquivo e a biblioteca será atualizada. Um backup permite desfazer."
                     : "As alterações serão mantidas apenas no Durvald, inclusive após novos scans.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .file:
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                row("Duração") { Text(DurationFormatter.text(info.track.durationSeconds)) }
                if let bitrate = info.track.bitrate { row("Bitrate") { Text("\(bitrate) kbps") } }
                if let rate = info.track.sampleRate { row("Amostragem") { Text("\(rate) Hz") } }
                if let depth = info.track.bitDepth { row("Profundidade") { Text("\(depth) bits") } }
                row("Localização") { Text(info.track.filePath).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }



    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                navigationButton(systemName: "chevron.left", offset: -1, label: "Música anterior")
                navigationButton(systemName: "chevron.right", offset: 1, label: "Próxima música")
            }
            Button("Desfazer última alteração") { Task { await undo() } }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(isSaving || info?.canUndo != true || editing.isDirty)
                .accessibilityIdentifier("trackInfo.undo")
            Spacer()
            Button(!editing.isDirty ? "Fechar" : "Cancelar") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .frame(width: 96, height: 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                .disabled(isSaving)
            Button("Salvar") { Task { await save() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .frame(width: 96, height: 24)
                .background(accent, in: RoundedRectangle(cornerRadius: 7))
                .disabled(isSaving || draft == nil || !editing.isDirty)
                .opacity(isSaving || draft == nil || !editing.isDirty ? 0.5 : 1)
                .accessibilityIdentifier("trackInfo.save")
        }
    }

    private func adjacentTrackID(offset: Int) -> Int64? {
        guard let index = navigationTrackIDs.firstIndex(of: trackID),
              navigationTrackIDs.indices.contains(index + offset) else { return nil }
        return navigationTrackIDs[index + offset]
    }

    private func navigationButton(systemName: String, offset: Int, label: String) -> some View {
        Button {
            guard !isSaving, !editing.isDirty, let id = adjacentTrackID(offset: offset) else { return }
            onSelectTrack(id)
        } label: {
            Image(systemName: systemName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(isSaving || draft == nil || editing.isDirty || adjacentTrackID(offset: offset) == nil)
        .help(editing.isDirty ? "Salve ou cancele as alterações antes de trocar de música." : label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(offset < 0 ? "trackInfo.previous" : "trackInfo.next")
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
                .frame(width: 120, height: 28, alignment: .trailing)
            content().frame(minHeight: 28, alignment: .leading)
        }
    }

    private func field(_ title: String, _ keyPath: WritableKeyPath<TrackMetadataDraft, String>, width: CGFloat? = nil, multiline: Bool = false) -> some View {
        let binding = Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { value in
                draft?[keyPath: keyPath] = value
                errorMessage = nil
                statusMessage = nil
            }
        )
        return row(title) {
            TextField("", text: binding, axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .lineLimit(multiline ? 2...4 : 1...1)
                .padding(.horizontal, 6).padding(.vertical, 5)
                .frame(width: width, alignment: .leading)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
                .overlay(Rectangle().stroke(.secondary.opacity(0.45), lineWidth: 1))
                .accessibilityLabel(title)
                .accessibilityIdentifier("trackInfo.field.\(title)")
        }
    }


    private func accept(_ value: TrackInfo) {
        info = value
        editing.reset(to: TrackMetadataDraft(value.metadata))
    }

    private func updateRating(_ rating: UInt8?) async -> Bool {
        guard let info else { return false }
        let succeeded = await store.setTrackRating(trackID: trackID, rating: rating, fallbackTrack: info.track)
        if let refreshed = try? await store.core?.trackInfo(trackId: trackID) { self.info = refreshed }
        return succeeded
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        editing.reset(to: nil)
        info = nil
        lyrics = nil
        lyricsLoaded = false
        statusMessage = nil
        let generation = editing.generation
        guard let core = store.core else {
            errorMessage = "A biblioteca ainda está abrindo. Tente novamente em instantes."
            return
        }
        do {
            let value = try await core.trackInfo(trackId: trackID)
            guard !Task.isCancelled, editing.generation == generation, store.core === core else { return }
            accept(value)
        } catch {
            guard !Task.isCancelled, editing.generation == generation, store.core === core else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard !isSaving, let draft, let core = store.core else { return }
        statusMessage = nil
        let metadata: TrackMetadataEdit
        do { metadata = try draft.metadata() }
        catch { errorMessage = "Não foi possível salvar: \(error.localizedDescription)"; return }
        guard let ticket = editing.beginSaving() else { return }
        do {
            let value = try await core.saveTrackMetadata(trackId: trackID, metadata: metadata, writeToFile: writeChangesToFiles)
            BatchMetadataOperationReceipt.clear()
            guard store.core === core else {
                editing.fail(ticket, message: "A biblioteca mudou durante a gravação."); return
            }
            await store.refreshAfterMetadataEdit(value)
            guard store.core === core else {
                editing.fail(ticket, message: "A biblioteca mudou durante a gravação."); return
            }
            guard editing.finish(ticket, confirmed: TrackMetadataDraft(value.metadata)) else { return }
            info = value
            statusMessage = "Salvo."
        } catch { editing.fail(ticket, message: "Não foi possível salvar: \(error.localizedDescription)") }
    }

    private func undo() async {
        guard !isSaving, let core = store.core, let ticket = editing.beginSaving() else { return }
        statusMessage = nil
        do {
            let value = try await core.undoTrackMetadata(trackId: trackID)
            BatchMetadataOperationReceipt.clear()
            guard store.core === core else {
                editing.fail(ticket, message: "A biblioteca mudou durante o desfazer."); return
            }
            await store.refreshAfterMetadataEdit(value)
            guard store.core === core else {
                editing.fail(ticket, message: "A biblioteca mudou durante o desfazer."); return
            }
            guard editing.finish(ticket, confirmed: TrackMetadataDraft(value.metadata)) else { return }
            info = value
            statusMessage = "Alteração desfeita."
        } catch { editing.fail(ticket, message: "Não foi possível desfazer: \(error.localizedDescription)") }
    }
}
