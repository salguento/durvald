import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var store: DurvaldCoreStore
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        // The native inspector owns the glass surface. A legacy sidebar material
        // or another glass layer here would obscure or double that surface.
        VStack(spacing: 0) {
            HStack {
                Text("Fila")
                    .font(.headline)

                Spacer()

                Button("Limpar") {
                    Task {
                        await store.clearQueue()
                    }
                }
                .disabled(upcomingItems.isEmpty)
                .accessibilityIdentifier("queue.clear")
            }
            .padding()

            Divider()

            // Size the AppKit viewport from the available space, not its document's
            // fitting size. The queue scrolls instead of raising the window minimum
            // during SwiftUI's size negotiation or a live resize.
            GeometryReader { geometry in
                QueueTableView(
                    rows: tableRows,
                    core: store.core,
                    isWindowActive: appearsActive,
                    onMove: { from, to in
                        store.moveQueueItem(from: from, to: to)
                    },
                    onPlay: { position in
                        Task {
                            await store.playQueueItem(at: position)
                        }
                    },
                    onTogglePlayback: {
                        Task {
                            await store.togglePause()
                        }
                    },
                    onRemove: { position in
                        Task {
                            await store.removeQueueItem(at: position)
                        }
                    }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.sidebar")
    }

    private var upcomingItems: [QueueItem] {
        Array(store.queue.dropFirst())
    }

    private var tableRows: [QueueTableRow] {
        store.queue.map { item in
            let track = store.tracks.first { $0.id == item.trackId }
            let isCurrent = item.position == 0

            return QueueTableRow(
                trackID: item.trackId,
                position: item.position,
                title: track?.title ?? "Música #\(item.trackId)",
                artist: track?.artist ?? "",
                artworkID: track?.artworkId,
                isCurrent: isCurrent,
                isPaused: isCurrent && (store.playback?.isPaused ?? true)
            )
        }
    }
}
