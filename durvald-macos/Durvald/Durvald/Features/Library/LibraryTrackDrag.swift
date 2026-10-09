import AppKit
import SwiftUI

@MainActor
enum LibraryTrackDrag {
    static let type = "public.utf8-plain-text"
    static let pasteboardType = NSPasteboard.PasteboardType.string

    private static func decode(_ value: String) -> Int64? {
        guard value.hasPrefix("durvald-track:") else { return nil }
        return Int64(value.dropFirst("durvald-track:".count))
    }

    static func ids(from pasteboard: NSPasteboard) -> [Int64] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.string(forType: pasteboardType).flatMap(decode)
        }
    }

    static func accept(_ providers: [NSItemProvider], perform: @escaping ([Int64]) -> Void) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(type) }
        guard !providers.isEmpty else { return false }
        Task {
            var ids: [Int64] = []
            for provider in providers {
                let data: Data? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                        continuation.resume(returning: data)
                    }
                }
                if let data, let value = String(data: data, encoding: .utf8), let id = decode(value) {
                    ids.append(id)
                }
            }
            if !ids.isEmpty { perform(ids) }
        }
        return true
    }
}

struct PlaylistDropTargetPreference: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct PlaylistTrackDropModifier: ViewModifier {
    @Environment(DurvaldCoreStore.self) private var store
    @State private var isTargeted = false
    let playlist: Playlist

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background {
                if isTargeted && !playlist.isSmart {
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor)
                }
            }
            .preference(key: PlaylistDropTargetPreference.self, value: isTargeted)
            .onDrop(of: [LibraryTrackDrag.type], isTargeted: $isTargeted) { providers in
                guard !playlist.isSmart else { return false }
                return LibraryTrackDrag.accept(providers) { ids in
                    Task { await store.addSelectionToPlaylist(ids, playlist: playlist) }
                }
            }
    }
}

extension View {
    func playlistTrackDropTarget(_ playlist: Playlist) -> some View {
        modifier(PlaylistTrackDropModifier(playlist: playlist))
    }
}
