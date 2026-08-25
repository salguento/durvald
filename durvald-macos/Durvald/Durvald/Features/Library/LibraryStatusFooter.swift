import SwiftUI

struct LibraryStatusFooter: View {
    let allTracks: [Track]
    let visibleTracks: [Track]
    let selectedTrackIDs: Set<Int64>
    let isFiltering: Bool

    var body: some View {
        Text(statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .frame(
                maxWidth: .infinity,
                minHeight: 26,
                maxHeight: 26,
                alignment: .center
            )
            .padding(.horizontal, 12)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("library.statusFooter")
    }

    private var statusText: String {
        let selectedTracks = allTracks.filter { selectedTrackIDs.contains($0.id) }

        if !selectedTracks.isEmpty {
            return "\(selectedTrackCount(selectedTracks.count)) • \(duration(selectedTracks))"
        }

        if isFiltering {
            return "\(visibleTracks.count.formatted()) de \(trackCount(allTracks.count)) • \(duration(visibleTracks))"
        }

        return "\(trackCount(allTracks.count)) • \(duration(allTracks))"
    }

    private func trackCount(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "música" : "músicas")"
    }

    private func selectedTrackCount(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "música selecionada" : "músicas selecionadas")"
    }

    private func duration(_ tracks: [Track]) -> String {
        let seconds = tracks.reduce(0.0) { partialResult, track in
            partialResult + max(track.durationSeconds, 0)
        }
        let totalMinutes = Int(seconds.rounded()) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours == 0 {
            return "\(totalMinutes) min"
        }

        return "\(hours) h \(minutes) min"
    }
}
