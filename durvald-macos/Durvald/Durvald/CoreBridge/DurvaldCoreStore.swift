import Foundation
import SwiftUI
import Combine
// import DurvaldCoreFFI // substitua pelo módulo efetivamente gerado

@MainActor
final class DurvaldCoreStore: ObservableObject {

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playback: PlaybackSnapshot?
    @Published private(set) var scanProgress: ScanProgress?
    @Published var errorMessage: String?

    private(set) var core: DurvaldCore?
    private var playbackPollingTask: Task<Void, Never>?
    private var scanProgressPollingTask: Task<Void, Never>?
    private static let libraryBookmarksKey = "durvald.library-security-bookmarks"
    private var activeLibraryScopes: [URL] = []
    private var volumeTask: Task<Void, Never>?

    func openCoreIfNeeded() async {
        guard core == nil else { return }

        do {
            restoreLibraryAccess()

            let openedCore = try await open(config: try makeConfig())
            let loadedTracks = try openedCore.tracks()
            let initialPlayback = openedCore.playback()

            core = openedCore
            tracks = loadedTracks
            playback = initialPlayback

            startPlaybackPolling()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func startPlaybackPolling() {
        playbackPollingTask?.cancel()

        playbackPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                if let core = self.core {
                    self.playback = core.playback()
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func makeConfig() throws -> CoreConfig {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Durvald", isDirectory: true)

        let config = CoreConfig(
            databasePath: appSupport.appendingPathComponent("music.db3").path,
            appSupportDir: appSupport.path,
            coversDir: appSupport.appendingPathComponent("covers").path,
            keychainService: "com.durvald.player"
        )
        return config
    }

    func addAndScanLibraryFolder(_ url: URL) {
        do {
            try saveAndStartLibraryAccess(for: url)
        } catch {
            errorMessage = "Não foi possível acessar a pasta selecionada: \(error)"
            return
        }

        Task {
            print("Durvald: pasta selecionada para scan: \(url.path)")
            guard let core else {
                errorMessage = "O core ainda está abrindo. Tente novamente em instantes."
                return
            }
            startScanProgressPolling()
            do {
                defer {
                    scanProgressPollingTask?.cancel()
                    scanProgressPollingTask = nil
                    scanProgress = nil
                }
                try core.addLibraryPath(path: url.path)
                let result = try await core.scanConfiguredLibrary()
                print(
                    "Durvald: scan concluído — encontrados: \(result.totalFilesFound), novos: \(result.newTracksAdded), atualizados: \(result.updatedTracks), erros: \(result.errors)"
                )
                let loadedTracks = try core.tracks()
                tracks = loadedTracks

                if !result.errors.isEmpty {
                    errorMessage = result.errors.joined(separator: "\n")
                } else if result.totalFilesFound == 0 {
                    errorMessage = "Nenhum arquivo suportado foi encontrado. O MVP aceita MP3, WAV, FLAC, Ogg Vorbis e OGA."
                } else {
                    print("Scan concluído: \(result.newTracksAdded) nova(s), \(result.updatedTracks) atualizada(s), \(tracks.count) faixa(s) na biblioteca.")
                }
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }

    func startScanProgressPolling() {
        scanProgressPollingTask?.cancel()
        scanProgressPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let core = self.core else { return }
                self.scanProgress = try? core.scanProgress()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func cancelScan() {
        guard let core else {
            errorMessage = "Não há core disponível para cancelar o scan."
            return
        }
        do { try core.cancelLibraryScan() }
        catch { errorMessage = String(describing: error) }
    }

    func play(trackID: Int64) async {
        print("Durvald: solicitando reprodução da faixa \(trackID).")
        guard let core else {
            errorMessage = "O core ainda está abrindo."
            return
        }
        do {
            let snapshot = try await core.play(trackId: trackID)
            playback = snapshot
            print("Durvald: reprodução iniciada; pausada: \(snapshot.isPaused).")
        } catch {
            print("Durvald: falha ao iniciar reprodução: \(error)")
            errorMessage = String(describing: error)
        }
    }

    private func saveAndStartLibraryAccess(for url: URL) throws {
        // Keep the exact URL returned by NSOpenPanel. Normalizing it before
        // opening the security scope can discard the sandbox authorization.
        let scopedURL = url
        let canonicalPath = scopedURL.standardizedFileURL.path
        if activeLibraryScopes.contains(where: { $0.standardizedFileURL.path == canonicalPath }) {
            return
        }

        let bookmark = try scopedURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = UserDefaults.standard.dictionary(forKey: Self.libraryBookmarksKey) ?? [:]
        bookmarks[canonicalPath] = bookmark
        UserDefaults.standard.set(bookmarks, forKey: Self.libraryBookmarksKey)

        guard scopedURL.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        activeLibraryScopes.append(scopedURL)
    }

    private func restoreLibraryAccess() {
        let bookmarks = UserDefaults.standard.dictionary(forKey: Self.libraryBookmarksKey) ?? [:]
        for value in bookmarks.values {
            guard let data = value as? Data else { continue }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            guard !activeLibraryScopes.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { continue }
            if url.startAccessingSecurityScopedResource() {
                activeLibraryScopes.append(url.standardizedFileURL)
            }
        }
    }

    func previous() async {
        guard let core else { return }
        do { playback = try await core.previousTrack() }
        catch { errorMessage = String(describing: error) }
    }

    func next() async {
        guard let core else { return }
        do { playback = try await core.nextTrack() }
        catch { errorMessage = String(describing: error) }
    }

    func togglePause() async {
        guard let core, let playback, playback.currentTrack != nil else { return }

        do {
            if playback.isPaused {
                try await core.resume()
            } else {
                try await core.pause()
            }

            self.playback = core.playback()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func setVolume(_ value: Double) async {
        guard let core else { return }
        do {
            try await core.setVolume(volume: Float(min(max(value, 0), 1)))
            playback = core.playback()
        } catch { errorMessage = String(describing: error) }
    }

    func seek(to seconds: Double) async {
        guard let core else { return }
        do {
            try await core.seek(seconds: UInt64(max(0, seconds)))
            playback = core.playback()
        } catch { errorMessage = String(describing: error) }
    }

    func scheduleVolume(_ value: Double, immediately: Bool = false) {
        volumeTask?.cancel()

        let normalized = Float(min(max(value, 0), 1))

        // Atualização otimista da interface.
        if var snapshot = playback {
            snapshot.volume = normalized
            playback = snapshot
        }

        volumeTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(50))
            }

            guard !Task.isCancelled, let self, let core = self.core else { return }

            do {
                try await core.setVolume(volume: normalized)
                self.playback = core.playback()
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = String(describing: error)
            }
        }
    }

    deinit {
        playbackPollingTask?.cancel()
        scanProgressPollingTask?.cancel()
        activeLibraryScopes.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}
