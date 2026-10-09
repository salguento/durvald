import AppKit
import SwiftUI
import XCTest
@testable import Durvald

@MainActor
final class MusicLibraryPerformanceTests: XCTestCase {
    func testDisplayRevisionReusesUnchangedKeyAndInvalidatesChangedPayload() async {
        let model = MusicLibraryPresentation()
        var track = Fixtures.track
        func request() -> MusicLibraryPresentation.DisplayRequest {
            .init(tracks: [track], query: "", onlyFavorites: false, sort: .title, ascending: true)
        }
        let key = MusicLibraryPresentation.DisplayKey(tracksRevision: 1)
        await model.prepare(request(), key: key)
        let revision = model.displayRevision
        await model.prepare(request(), key: key)
        XCTAssertEqual(model.displayRevision, revision)
        track.rating = 5
        await model.prepare(request(), key: .init(tracksRevision: 2))
        XCTAssertEqual(model.displayRevision, revision + 1)
        XCTAssertEqual(model.displayedTracks.first?.rating, 5)
    }

    func testStoreRevisionTracksOptimisticChangesAndRollback() async {
        let fake = FakeDurvaldCore(snapshot: Fixtures.playingSnapshot)
        let store = DurvaldCoreStore(core: fake, tracks: [Fixtures.track])
        let before = store.tracksRevision
        await store.setTrackRating(trackID: Fixtures.track.id, rating: 3)
        XCTAssertGreaterThan(store.tracksRevision, before)
        XCTAssertEqual(store.tracks.first?.rating, 3)
        let request = MusicLibraryPresentation().catalogRequest(for: store)
        fake.trackRatingError = NSError(domain: "test", code: 1)
        let metadataRevision = store.metadataRevision
        let beforeRollback = store.tracksRevision
        await store.setTrackRating(trackID: Fixtures.track.id, rating: 5)
        XCTAssertEqual(store.tracks.first?.rating, 3)
        XCTAssertEqual(store.metadataRevision, metadataRevision + 1, "Rollback invalidates collection snapshots too")
        XCTAssertGreaterThanOrEqual(store.tracksRevision, beforeRollback + 2)
        XCTAssertNotEqual(MusicLibraryPresentation().catalogRequest(for: store), request)
    }

    func testScrollRestorationPreservesIndependentHistoryPositions() throws {
        var offsets: [Int: CGFloat] = [1: 0, 2: 0]
        let tracks = (1...200).map { Fixtures.track(id: Int64($0), trackNumber: 1, discNumber: 1) }
        func page(entryID: Int, visible: Bool = true) -> MusicLibraryTableView {
            MusicLibraryTableView(tracks: tracks, selection: .constant([]),
                                  savedScrollOffset: Binding(get: { offsets[entryID] ?? 0 }, set: { offsets[entryID] = $0 }),
                                  layout: MusicLibraryColumnLayout(), ratingsEnabled: true, artworkSize: 32,
                                  groupArtwork: false, activeTrackID: nil, isPresented: visible,
                                  scrollRestorationID: entryID, onLayoutChange: { _ in },
                                  onPlay: { _ in }, onLoadMore: { _ in }, configureMenu: { _, _ in },
                                  cellContent: { _, _ in AnyView(EmptyView()) })
        }
        let host = NSHostingView(rootView: page(entryID: 1))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        settle()
        let table = try XCTUnwrap(descendants(host).first { $0 is NSTableView } as? NSTableView)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        // AppKit reserves the native table header inside the clip view. Saved
        // offsets measure distance from that inset-adjusted top, not document Y.
        let topOrigin = -scroll.contentView.contentInsets.top
        XCTAssertEqual(scroll.contentView.contentInsets.top, try XCTUnwrap(table.headerView).frame.height, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, topOrigin, accuracy: 0.5)
        XCTAssertEqual(offsets[1] ?? -1, 0, accuracy: 0.5)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: topOrigin + 320))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        XCTAssertEqual(offsets[1] ?? -1, 320, accuracy: 0.5)
        host.rootView = page(entryID: 1, visible: false)
        settle()
        host.rootView = page(entryID: 2)
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, topOrigin, accuracy: 0.5)
        XCTAssertEqual(offsets[1] ?? -1, 320, accuracy: 0.5)
        host.rootView = page(entryID: 1)
        settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, topOrigin + 320, accuracy: 0.5)
        XCTAssertEqual(offsets[2] ?? -1, 0, accuracy: 0.5)
        // A saved offset beyond the current document is constrained safely.
        offsets[2] = 100_000
        host.rootView = page(entryID: 2)
        settle()
        let maximum = max(0, table.frame.height - scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.contentView.bounds.minY, maximum, accuracy: 1)
    }

    func testSwiftUIVisibilityChangesPreserveNativeTableIdentity() throws {
        func page(visible: Bool, entryID: Int = 1) -> MusicLibraryTableView {
            MusicLibraryTableView(tracks: [Fixtures.track], selection: .constant([]),
                                  savedScrollOffset: .constant(0), layout: MusicLibraryColumnLayout(),
                                  ratingsEnabled: true, artworkSize: 32, groupArtwork: false,
                                  activeTrackID: nil, isPresented: visible, scrollRestorationID: entryID,
                                  onLayoutChange: { _ in }, onPlay: { _ in }, onLoadMore: { _ in },
                                  configureMenu: { _, _ in }, cellContent: { _, _ in AnyView(EmptyView()) })
        }
        let host = NSHostingView(rootView: page(visible: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let table = try XCTUnwrap(descendants(host).first { $0 is NSTableView } as? NSTableView)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        host.rootView = page(visible: false)
        settle()
        XCTAssertTrue(descendants(host).contains { $0 === table })
        XCTAssertTrue(table.isHiddenOrHasHiddenAncestor)
        host.rootView = page(visible: true, entryID: 2)
        settle()
        XCTAssertTrue(descendants(host).contains { $0 === table })
        XCTAssertTrue(table.enclosingScrollView === scroll)
        XCTAssertFalse(table.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(table.numberOfRows, 1)
    }

    func testNativeControlsToggleClearAndReplaceActionsOnReuse() async {
        let favorite = MusicLibraryNativeControlCell(identifier: .init("favorite"), kind: .favorite)
        var favoriteChanges: [Bool] = []
        favorite.configure(track: Fixtures.track, selected: false,
                           onFavoriteChange: { favoriteChanges.append($0); return true }, onRatingChange: { _ in true })
        XCTAssertTrue(favorite.buttons[0].isHidden)
        let row = HoveringMusicRow()
        row.addSubview(favorite)
        row.isHovered = true
        favorite.updateHoverVisibility()
        XCTAssertFalse(favorite.buttons[0].isHidden)
        row.isHovered = false
        favorite.updateHoverVisibility()
        XCTAssertTrue(favorite.buttons[0].isHidden)
        favorite.buttons[0].performClick(nil)
        await Task.yield()
        XCTAssertEqual(favoriteChanges, [true])
        XCTAssertFalse(favorite.buttons[0].isHidden)
        XCTAssertEqual(favorite.buttons[0].accessibilityLabel(), "Desfavoritar faixa")
        var replacementChanges: [Bool] = []
        var replacement = Fixtures.track(id: 2, trackNumber: 2, discNumber: 1)
        replacement.isFavorite = true
        favorite.configure(track: replacement, selected: true,
                           onFavoriteChange: { replacementChanges.append($0); return true }, onRatingChange: { _ in true })
        favorite.buttons[0].performClick(nil)
        await Task.yield()
        XCTAssertEqual(favoriteChanges, [true])
        XCTAssertEqual(replacementChanges, [false])
        XCTAssertEqual(favorite.buttons[0].accessibilityIdentifier(), "track.2.favorite")
        let rating = MusicLibraryNativeControlCell(identifier: .init("rating"), kind: .rating)
        var ratings: [UInt8?] = []
        rating.configure(track: Fixtures.track, selected: false,
                         onFavoriteChange: { _ in true }, onRatingChange: { ratings.append($0); return true })
        rating.buttons[2].performClick(nil)
        await Task.yield()
        XCTAssertEqual(ratings.count, 1)
        XCTAssertEqual(ratings[0], 3)
        XCTAssertTrue(rating.buttons.allSatisfy { !$0.isHidden })
        rating.buttons[2].performClick(nil)
        await Task.yield()
        XCTAssertEqual(ratings.count, 2)
        XCTAssertNil(ratings[1])
        XCTAssertTrue(rating.buttons.allSatisfy(\.isHidden))
        XCTAssertTrue(favorite.subviews.allSatisfy { $0 is NSButton })
        XCTAssertTrue(rating.subviews.allSatisfy { $0 is NSButton })
    }

    func testPreparedListRespondsToSearchFavoritesSortAndMetadataChanges() async {
        let model = MusicLibraryPresentation()
        var first = Fixtures.track
        first.title = "Zulu"
        first.isFavorite = true
        var second = Fixtures.track(id: 2, trackNumber: 2, discNumber: 1)
        second.title = "Alpha"
        func request(query: String = "", favorites: Bool = false, ascending: Bool = true) -> MusicLibraryPresentation.DisplayRequest {
            .init(tracks: [first, second], query: query, onlyFavorites: favorites, sort: .title, ascending: ascending)
        }
        await model.prepare(request(), key: .init(tracksRevision: 1))
        XCTAssertEqual(model.displayedTracks.map(\.id), [2, 1])
        await model.prepare(request(ascending: false), key: .init(tracksRevision: 1, ascending: false))
        XCTAssertEqual(model.displayedTracks.map(\.id), [1, 2])
        await model.prepare(request(query: "ALPHA"), key: .init(tracksRevision: 1, query: "ALPHA"))
        XCTAssertEqual(model.displayedTracks.map(\.id), [2])
        await model.prepare(request(favorites: true), key: .init(tracksRevision: 1, onlyFavorites: true))
        XCTAssertEqual(model.displayedTracks.map(\.id), [1])
        first.title = "Aardvark"
        await model.prepare(request(), key: .init(tracksRevision: 2))
        XCTAssertEqual(model.displayedTracks.map(\.id), [1, 2])
    }

    func testCatalogSummarySurvivesNavigationAndInvalidatesChangedTracks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0, count: 32).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var track = Fixtures.track
        track.filePath = url.path
        let store = DurvaldCoreStore(tracks: [track])
        let model = MusicLibraryPresentation()
        await model.refreshCatalog(store: store)
        XCTAssertEqual(model.librarySummary?.totalBytes, 32)
        XCTAssertTrue(model.displayedTracks.isEmpty, "Summary loading must not replace the displayed list")
        try FileManager.default.removeItem(at: url)
        await model.refreshCatalog(store: store)
        XCTAssertEqual(model.librarySummary?.totalBytes, 32, "An unchanged visit must reuse the cached summary")
        track.durationSeconds = 240
        await model.refreshCatalog(store: DurvaldCoreStore(tracks: [track]))
        XCTAssertEqual(model.librarySummary?.durationSeconds, 240)
        XCTAssertNil(model.librarySummary?.totalBytes)
    }

    func testActiveTrackAndMetadataUpdatesDoNotReloadOrResizeWholeTable() {
        let tracks = [Fixtures.track, Fixtures.track(id: 2, trackNumber: 2, discNumber: 1)]
        func view(_ tracks: [Track], active: Int64?, grouped: Bool = false, artwork: Double = 32, revision: UInt64 = 1) -> MusicLibraryTableView {
            MusicLibraryTableView(tracks: tracks, selection: .constant([]), savedScrollOffset: .constant(0),
                                  layout: MusicLibraryColumnLayout(), ratingsEnabled: true,
                                  artworkSize: artwork, groupArtwork: grouped, activeTrackID: active, tracksRevision: revision,
                                  onLayoutChange: { _ in }, onPlay: { _ in }, onLoadMore: { _ in },
                                  configureMenu: { _, _ in }, cellContent: { _, _ in AnyView(EmptyView()) })
        }
        let table = RecordingMusicTable()
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        let coordinator = view(tracks, active: 1).makeCoordinator()
        coordinator.tableView = table
        coordinator.updateRows()
        XCTAssertEqual(table.fullReloads, 1)
        let initialSizes = table.resizes
        coordinator.parent = view(tracks, active: 2)
        coordinator.updateRows()
        XCTAssertEqual(table.fullReloads, 1)
        XCTAssertEqual(table.reloadedRows, IndexSet([0, 1]))
        XCTAssertEqual(table.resizes, initialSizes)
        var changed = tracks
        changed[1].isFavorite = true
        coordinator.parent = view(changed, active: 2, revision: 2)
        coordinator.updateRows()
        XCTAssertEqual(table.reloadedRows, IndexSet(integer: 1))
        XCTAssertEqual(table.fullReloads, 1)
        XCTAssertEqual(table.resizes, initialSizes)
        coordinator.parent = view(Array(changed.reversed()), active: 2, revision: 3)
        coordinator.updateRows()
        XCTAssertEqual(table.fullReloads, 2, "Reordering requires a structural update")
        coordinator.parent = view(changed, active: 2, grouped: true, revision: 4)
        coordinator.updateRows()
        XCTAssertEqual(coordinator.numberOfRows(in: table), 3, "Short album groups retain spacer rows")
        coordinator.parent = view(changed, active: 2, grouped: true, artwork: 96, revision: 4)
        coordinator.updateRows()
        XCTAssertEqual(coordinator.numberOfRows(in: table), 4)
        coordinator.parent = view(changed, active: 2, revision: 2)
        coordinator.updateRows()
        XCTAssertEqual(coordinator.numberOfRows(in: table), 2)
    }
}

@MainActor
private final class RecordingMusicTable: NSTableView {
    var fullReloads = 0
    var resizes = 0
    var reloadedRows = IndexSet()
    override func reloadData() { fullReloads += 1 }
    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) { reloadedRows = rowIndexes }
    override func sizeToFit() { resizes += 1 }
}

@MainActor
private final class HoveringMusicRow: NSView, MusicLibraryRowHoverProviding {
    var isHovered = false
}
