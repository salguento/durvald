import AppKit
import SwiftUI
import XCTest
@testable import Durvald

@MainActor
final class NativeSidebarPaneTests: XCTestCase {
    func testNativeSidebarForwardsEnvironmentAndKeepsContentStateOnUpdate() throws {
        let first = DurvaldCoreStore()
        let second = DurvaldCoreStore()
        let info = TrackInfoCoordinator()
        let creation = PlaylistCreationCoordinator()
        var readings: [PaneReading] = []
        var navigated = false
        func pane(store: DurvaldCoreStore) -> some View {
            NativeSidebarPane {
                PaneProbe { readings.append($0) }
            }
            .frame(width: 300, height: 400)
            .environment(store)
            .environment(info)
            .environment(creation)
            .environment(\.appearsActive, false)
            .environment(\.trackMenuNavigation, TrackMenuNavigation(playlist: { _ in navigated = true }))
        }
        let host = NSHostingView(rootView: pane(store: first))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let initial = try XCTUnwrap(readings.last)
        XCTAssertEqual(initial.storeID, ObjectIdentifier(first))
        XCTAssertEqual(initial.infoID, ObjectIdentifier(info))
        XCTAssertEqual(initial.creationID, ObjectIdentifier(creation))
        XCTAssertFalse(initial.active)
        let playlist = Playlist(id: 1, name: "Test", description: "", artworkId: nil, isFavorite: false,
            suggestLess: false, trackCount: 0, createdAt: "", updatedAt: "", isSmart: false, smartDefinition: nil)
        initial.navigation.playlist(playlist)
        XCTAssertTrue(navigated)
        host.rootView = pane(store: second)
        settle()
        let updated = try XCTUnwrap(readings.last)
        XCTAssertEqual(updated.storeID, ObjectIdentifier(second))
        XCTAssertEqual(updated.stateID, initial.stateID, "Updating the environment must not reset the queue's panel/selection state")
        let controller = try XCTUnwrap(descendants(host).compactMap { $0.nextResponder as? NativeSidebarPaneController }.first)
        XCTAssertEqual(controller.splitViewItems.count, 1)
        XCTAssertEqual(controller.splitViewItems.first?.behavior, .sidebar)
        XCTAssertFalse(controller.splitViewItems.first?.canCollapse ?? true)
        XCTAssertEqual(controller.view.bounds.width, 300, accuracy: 1)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

private struct PaneReading {
    let storeID: ObjectIdentifier
    let infoID: ObjectIdentifier
    let creationID: ObjectIdentifier
    let active: Bool
    let stateID: UUID
    let navigation: TrackMenuNavigation
}

private struct PaneProbe: View {
    @Environment(DurvaldCoreStore.self) private var store
    @Environment(TrackInfoCoordinator.self) private var info
    @Environment(PlaylistCreationCoordinator.self) private var creation
    @Environment(\.appearsActive) private var active
    @Environment(\.trackMenuNavigation) private var navigation
    @State private var stateID = UUID()
    let record: (PaneReading) -> Void

    var body: some View {
        PaneReadingView(reading: PaneReading(storeID: ObjectIdentifier(store), infoID: ObjectIdentifier(info),
            creationID: ObjectIdentifier(creation), active: active, stateID: stateID, navigation: navigation), record: record)
    }
}

private struct PaneReadingView: NSViewRepresentable {
    let reading: PaneReading
    let record: (PaneReading) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { record(reading) }
}
