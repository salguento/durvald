import AppKit
import SwiftUI
import Combine

@MainActor
final class LastFmViewModel: ObservableObject {
    @Published var apiKey = ""
    @Published var apiSecret = ""
    @Published var status: LastFmStatus?
    @Published var pendingToken: String?
    @Published var isWorking = false
    @Published var errorMessage: String?

    func refresh(using core: DurvaldCore) async {
        do {
            status = try await core.lastfmStatus()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func beginAuthorization(using core: DurvaldCore) async {
        isWorking = true
        defer { isWorking = false }

        do {
            try await core.configureLastfm(
                apiKey: apiKey,
                apiSecret: apiSecret
            )

            let response = try await core.lastfmAuthToken()
            pendingToken = response.token

            guard let url = URL(string: response.authUrl) else {
                throw URLError(.badURL)
            }

            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func completeAuthorization(using core: DurvaldCore) async {
        guard let pendingToken else { return }

        do {
            _ = try await core.completeLastfmAuth(token: pendingToken)
            self.pendingToken = nil
            status = try await core.lastfmStatus()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func disconnect(using core: DurvaldCore) async {
        do {
            try await core.disconnectLastfm()
            pendingToken = nil
            status = try await core.lastfmStatus()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
