import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var store: DurvaldCoreStore

    var body: some View {
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

            QueueTableView(
                rows: tableRows,
                core: store.core,
                onMove: { from, to in
                    store.moveQueueItem(from: from, to: to)
                },
                onPlay: { position in
                    Task {
                        await store.playQueueItem(at: position)
                    }
                },
                onRemove: { position in
                    Task {
                        await store.removeQueueItem(at: position)
                    }
                }
            )
            .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .background(.bar, ignoresSafeAreaEdges: .all)
    }

    private var upcomingItems: [QueueItem] {
        Array(store.queue.dropFirst())
    }

    private var tableRows: [QueueTableRow] {
        store.queue.map { item in
            let track = store.tracks.first { $0.id == item.trackId }
            return QueueTableRow(
                trackID: item.trackId,
                position: item.position,
                title: track?.title ?? "Música #\(item.trackId)",
                artist: track?.artist ?? "",
                artworkID: track?.artworkId
            )
        }
    }
}
