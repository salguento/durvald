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

            if let activeItem = store.queue.first,
               activeItem.position == 0 {
                activeRow(activeItem)
                    .padding(.horizontal, 10)
                    .frame(height: 46)
                Divider()
            }

            QueueTableView(
                rows: tableRows,
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
    }

    private var upcomingItems: [QueueItem] {
        Array(store.queue.dropFirst())
    }

    private var tableRows: [QueueTableRow] {
        upcomingItems.map { item in
            let track = store.tracks.first { $0.id == item.trackId }
            return QueueTableRow(
                trackID: item.trackId,
                position: item.position,
                title: track?.title ?? "Música #\(item.trackId)",
                artist: track?.artist ?? ""
            )
        }
    }

    private func activeRow(_ item: QueueItem) -> some View {
        let track = store.tracks.first { $0.id == item.trackId }

        return HStack {
            VStack(alignment: .leading) {
                Text(track?.title ?? "Música #\(item.trackId)")
                Text(track?.artist ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "speaker.wave.2.fill")
                .accessibilityLabel("Tocando agora")
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("queue.item.0")
    }
}
