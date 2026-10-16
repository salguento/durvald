//
//  RetrospectiveView.swift
//  Durvald
//
//  Created by Humberto Salguento on 21/08/26.
//

import AppKit
import SwiftUI

struct RetrospectiveView: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Binding var searchText: String
    @AppStorage("history.newestFirst") private var newestFirst = true
    @AppStorage(RetrospectivePeriod.storageKey) private var period = RetrospectivePeriod.defaultValue
    @State private var search = SearchPresentation<RetrospectiveListingSnapshot>()
    @State private var selectedDate: Date?
    @State private var selectedScope: Date?
    @State private var dateTabs = PreparedLibraryListing(RetrospectiveDateNavigation())
    @State private var overview = PreparedLibraryListing(RetrospectiveWeekSnapshot())
    @State private var playlistPreview: ReplayPreview?
    @State private var completedPlaylistKey: LibraryListingKey?
    @State private var statisticsDate = Date()
    private var snapshot: RetrospectiveListingSnapshot { search.value ?? RetrospectiveListingSnapshot() }
    private var searchPending: Bool { store.historyRepository.isLoading || search.isPending }
    var onOpenPlaylist: (RetrospectivePlaylistDraft) -> Void = { _ in }
    var onSummaryChange: (String) -> Void = { _ in }

    private struct RefreshRequest: Equatable {
        let coreID: ObjectIdentifier?
        let catalogRevision: UInt64
        let tracksRevision: UInt64
    }
    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var preparationKey: LibraryListingKey {
        LibraryListingKey(storeID: ObjectIdentifier(store), payloadRevision: store.historyRepository.revision,
                          scope: periodKey, query: query, newestFirst: newestFirst)
    }

    private var visibleTabs: [RetrospectiveDateTab] {
        dateTabs.completedKey == tabsKey ? dateTabs.value.tabs : []
    }
    private var selectedTab: RetrospectiveDateTab? {
        RetrospectiveDateTab.selection(in: visibleTabs, preferredDate: selectedDate, now: statisticsDate)
    }
    private var selectedInterval: DateInterval? { selectedTab?.interval }
    private var tabsKey: LibraryListingKey {
        LibraryListingKey(storeID: ObjectIdentifier(store), payloadRevision: store.historyRepository.revision,
                          scope: period.rawValue, query: "\(calendarKey):\(selectedScope?.timeIntervalSince1970 ?? 0)")
    }
    private var calendarKey: String {
        let calendar = Calendar.current
        return "\(calendar.startOfDay(for: statisticsDate).timeIntervalSince1970):\(calendar.timeZone.identifier):\(calendar.firstWeekday)"
    }
    private var periodKey: String {
        "\(period.rawValue):\(selectedInterval?.start.timeIntervalSince1970 ?? 0):\(calendarKey)"
    }

    private var overviewKey: LibraryListingKey {
        return LibraryListingKey(storeID: ObjectIdentifier(store), releasesRevision: store.releasesRevision,
                                 payloadRevision: store.historyRepository.revision,
                                 scope: "retrospective.overview", query: periodKey)
    }

    private var playlistKey: LibraryListingKey {
        LibraryListingKey(storeID: ObjectIdentifier(store), payloadRevision: store.historyRepository.revision,
                          scope: "retrospective.playlist.eligibility", query: "\(periodKey):\(store.playlistsRevision)")
    }

    private var availablePlaylistDraft: RetrospectivePlaylistDraft? {
        guard !store.historyRepository.isLoading, completedPlaylistKey == playlistKey,
              let interval = selectedInterval else { return nil }
        let draft = RetrospectivePlaylistDraft(period: period, interval: interval)
        return playlistPreview?.available == true ? draft : nil
    }

    var body: some View {
        // A concrete container keeps the titlebar accessory attached while the
        // conditional page changes. Group forwards its background to each page.
        GeometryReader { visible in
            GeometryReader { canvas in
                let viewport = PageViewport(visibleFrame: visible.frame(in: .global),
                                            canvasFrame: canvas.frame(in: .global))
                ZStack {
                    ScrollView {
                        VStack(spacing: 0) {
                            RetrospectiveOverviewHeader(snapshot: overview.value)
                            RetrospectiveRankingSection(snapshot: overview.value.rankings, viewport: viewport)
                            if let draft = availablePlaylistDraft {
                                RetrospectivePlaylistBanner(draft: draft, tracks: playlistPreview?.tracks ?? [],
                                                            onOpen: onOpenPlaylist)
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 32)
                            }
                            if !snapshot.items.isEmpty {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    Text("Reproduções").font(.headline)
                                    ForEach(snapshot.items, id: \.id) { item in
                                        RetrospectiveTrackRow(item: item, loadedTrack: snapshot.tracksByID[item.trackId])
                                            .accessibilityIdentifier("retrospective.entry.\(item.id)")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(24)
                            } else if !query.isEmpty && !searchPending {
                                ContentUnavailableView("Nenhuma reprodução encontrada", systemImage: "magnifyingglass")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                    .overlay {
                        if (store.historyRepository.isLoading || overview.isPreparing || dateTabs.isPreparing) && overview.value.days.isEmpty {
                            ProgressView("Carregando retrospectiva…")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RetrospectiveToolbarAccessory(height: 46) {
                HStack(spacing: 0) {
                    RetrospectiveTabPicker(tabs: visibleTabs, selection: selectedTab?.id) { selectedDate = $0 }
                        .frame(minWidth: 0)
                    if period != .yearly, let scope = dateTabs.value.selectedScope,
                       dateTabs.completedKey?.scope == period.rawValue {
                        Divider()
                            .frame(width: 1, height: 30)
                            .overlay(Color.primary.opacity(0.3))
                            .accessibilityHidden(true)
                        Picker(period == .monthly ? "Ano" : "Mês", selection: Binding(
                            get: { scope },
                            set: { selectedScope = $0; selectedDate = nil }
                        )) {
                            ForEach(dateTabs.value.scopes) { scope in
                                Text(scope.title).tag(scope.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel(period == .monthly ? "Ano da retrospectiva" : "Mês da retrospectiva")
                        .accessibilityIdentifier("retrospective.dateScope")
                        .padding(.horizontal, 8)
                    }
                }
            }
        }
        .task(id: RefreshRequest(coreID: store.core.map(ObjectIdentifier.init),
                                 catalogRevision: store.libraryCatalogRevision, tracksRevision: store.tracksRevision)) {
            await store.refreshHistory()
        }
        .task(id: tabsKey) {
            let selectedPeriod = period
            let now = statisticsDate
            let calendar = Calendar.current
            let preferredScope = selectedScope
            await dateTabs.prepare(key: tabsKey, payload: store.historyRepository.entries) { entries in
                RetrospectiveDateNavigation.build(period: selectedPeriod, now: now, calendar: calendar,
                                                   entries: entries, preferredScope: preferredScope)
            }
        }
        .onChange(of: period) { _, _ in selectedDate = nil; selectedScope = nil }
        .task(id: preparationKey) {
            let key = preparationKey
            let entries = store.historyRepository.entries
            let tracks = store.historyRepository.tracksByID
            let selectedPeriod = period
            let interval = selectedInterval
            let now = Date()
            let calendar = Calendar.current
            let current = SearchRequest(query: key.query, storeID: ObjectIdentifier(store),
                                        sourceRevision: key.payloadRevision, scope: key.scope)
            let published = await search.run(current, timing: .retrospective, allowsEmpty: true,
                                             isCurrent: { preparationKey == key }) { _ in
                let worker = Task.detached(priority: .userInitiated) {
                    RetrospectiveListingSnapshot.build(entries: entries.filter { selectedPeriod.contains($0, now: now, calendar: calendar, selectedInterval: interval) },
                                                       tracks: tracks, key: key)
                }
                return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            }
            guard published else { return }
            onSummaryChange(snapshot.summary)
        }
        .task(id: overviewKey) {
            let interval = selectedInterval
            let now = Date()
            let selectedPeriod = period
            let calendar = Calendar.current
            let payload = (store.historyRepository.entries, store.historyRepository.tracksByID, store.releases)
            await overview.prepare(key: overviewKey, payload: payload) { payload in
                RetrospectiveWeekSnapshot.build(entries: payload.0, now: now, calendar: calendar,
                                          tracksByID: payload.1, releases: payload.2, period: selectedPeriod, referenceDate: interval?.start)
            }
        }
        .task(id: playlistKey) {
            let key = playlistKey
            guard let interval = selectedInterval else { return }
            let draft = RetrospectivePlaylistDraft(period: period, interval: interval)
            let result = await store.loadReplayPreview(draft)
            guard !Task.isCancelled else { return }
            playlistPreview = result
            completedPlaylistKey = key
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            statisticsDate = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            statisticsDate = Date()
        }
        .onChange(of: searchPending) { _, loading in
            if loading && !query.isEmpty { onSummaryChange("Pesquisando…") }
            else { onSummaryChange(snapshot.summary) }
        }
        .onDisappear { search.cancel() }
    }

}

/// Keep every date label visible and the native toolbar accessory stable while scrolling.
private struct RetrospectiveTabPicker: View {
    let tabs: [RetrospectiveDateTab]
    let selection: Date?
    let onSelect: (Date) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(tabs) { tab in
                        Button { onSelect(tab.id) } label: {
                            Text(tab.title)
                                .font(.system(size: 14, weight: selection == tab.id ? .semibold : .regular))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(selection == tab.id ? Color.black : Color.secondary)
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background(selection == tab.id ? Color.white.opacity(0.94) : Color.primary.opacity(0.08), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == tab.id ? .isSelected : [])
                        .accessibilityIdentifier("retrospective.date.\(Int(tab.id.timeIntervalSince1970))")
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection, initial: true) { _, date in
                if let date { proxy.scrollTo(date, anchor: .center) }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("retrospective.tabs")
    }
}

struct RetrospectiveToolbarOptionsMenu: View {
    @AppStorage(RetrospectivePeriod.storageKey) private var period = RetrospectivePeriod.defaultValue

    var body: some View {
        ToolbarOptionsButton(title: "Opções de visualização") {
            Picker("Período", selection: $period) {
                ForEach(RetrospectivePeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.inline)
        }
        .accessibilityIdentifier("retrospective.viewOptions")
    }
}

private struct RetrospectiveTrackRow: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(TrackInfoCoordinator.self) private var trackInfo
    let item: PlaybackHistoryItem
    let loadedTrack: Track?

    var body: some View {
        let track = loadedTrack
        Group {
            if let track {
                label(track.title)
                    .trackContextMenu(track: track) {
                        Task { await TrackRowPlayback.track(track.id).perform(using: store) }
                    }
            } else {
                label("Música #\(item.trackId)")
                    .contextMenu {
                        Button("Info") { trackInfo.open(trackID: item.trackId) }
                    }
            }
        }

    }

    private func label(_ title: String) -> some View {
        TrackRowText(model: TrackRowModel(trackID: item.trackId, title: title),
                     subtitle: playbackDate, spacing: nil, lineLimit: nil)
    }

    private var playbackDate: String {
        guard let date = RetrospectivePeriod.playbackDate(item.playedAt) else { return item.playedAt }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(Locale(identifier: "pt_BR")))
    }
}
