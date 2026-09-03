import SwiftUI

struct LastFmSettingsView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @StateObject private var viewModel = LastFmViewModel()

    var body: some View {
        Form {
            if viewModel.status?.connected == true {
                Text("Conectado como \(viewModel.status?.username ?? "usuário")")
                Button("Desconectar") {
                    guard let core = store.core else { return }
                    Task { await viewModel.disconnect(using: core) }
                }
                .accessibilityIdentifier("settings.lastfm.disconnect")
            } else {
                TextField("API key", text: $viewModel.apiKey)
                SecureField("API secret", text: $viewModel.apiSecret)

                Button("Autorizar no Last.fm") {
                    guard let core = store.core else { return }
                    Task { await viewModel.beginAuthorization(using: core) }
                }
                .disabled(
                    viewModel.apiKey.isEmpty ||
                    viewModel.apiSecret.isEmpty ||
                    viewModel.isWorking
                )
                .accessibilityIdentifier("settings.lastfm.connect")

                if viewModel.pendingToken != nil {
                    Button("Concluir autorização") {
                        guard let core = store.core else { return }
                        Task { await viewModel.completeAuthorization(using: core) }
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .task(id: store.appSettings != nil) {
            guard let core = store.core else { return }
            await viewModel.refresh(using: core)
        }
    }
}
