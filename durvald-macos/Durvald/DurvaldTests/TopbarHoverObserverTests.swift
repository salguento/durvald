import XCTest
import AppKit
import SwiftUI
@testable import Durvald

@MainActor
final class TopbarHoverObserverTests: XCTestCase {
    func testHoverRegionUsesNativeTitlebarAndExcludesAdjacentPanels() {
        let region = TopbarHoverGeometry.region(page: NSRect(x: 200, y: 0, width: 450, height: 592),
            layout: NSRect(x: 0, y: 0, width: 900, height: 592), frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        XCTAssertEqual(region, NSRect(x: 200, y: 592, width: 450, height: 28))
        XCTAssertTrue(hovered(NSPoint(x: 300, y: 600), in: region))
        XCTAssertFalse(hovered(NSPoint(x: 100, y: 600), in: region))
        XCTAssertFalse(hovered(NSPoint(x: 800, y: 600), in: region))
        XCTAssertFalse(hovered(NSPoint(x: 300, y: 580), in: region))
        XCTAssertFalse(hovered(NSPoint(x: 300, y: 620), in: region))
    }

    func testRegionClipsToFrameAndHandlesMissingTitlebarOrCollapsedPage() {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let layout = NSRect(x: 0, y: 0, width: 600, height: 372)
        XCTAssertEqual(TopbarHoverGeometry.region(page: NSRect(x: -100, y: 0, width: 800, height: 372), layout: layout, frame: frame),
            NSRect(x: 0, y: 372, width: 600, height: 28))
        XCTAssertTrue(TopbarHoverGeometry.region(page: frame, layout: frame, frame: frame).isEmpty)
        XCTAssertTrue(TopbarHoverGeometry.region(page: NSRect(x: 200, y: 0, width: 0, height: 300), layout: layout, frame: frame).isEmpty)
        XCTAssertTrue(TopbarHoverGeometry.region(page: NSRect(x: 800, y: 0, width: 50, height: 300), layout: layout, frame: frame).isEmpty)
    }

    func testInactiveHiddenAndMiniaturizedWindowsNeverHover() {
        let region = NSRect(x: 0, y: 100, width: 300, height: 28)
        let point = NSPoint(x: 100, y: 110)
        XCTAssertFalse(TopbarHoverGeometry.contains(point, region: region, appActive: false, windowVisible: true, miniaturized: false))
        XCTAssertFalse(TopbarHoverGeometry.contains(point, region: region, appActive: true, windowVisible: false, miniaturized: false))
        XCTAssertFalse(TopbarHoverGeometry.contains(point, region: region, appActive: true, windowVisible: true, miniaturized: true))
    }

    func testTrackingAreaLivesOnNativeFrameAndLeavesCloseButtonHittable() throws {
        let fixture = makeFixture()
        defer { fixture.observer.stopObserving(); fixture.window.close() }
        let host = try XCTUnwrap(fixture.window.contentView?.superview)
        host.layoutSubtreeIfNeeded()
        fixture.observer.refreshTrackingRegion()
        let area = try XCTUnwrap(fixture.observer.nativeTrackingArea)
        XCTAssertTrue(host.trackingAreas.contains { $0 === area })
        XCTAssertTrue(area.owner as AnyObject === fixture.observer)
        XCTAssertNil(fixture.observer.hitTest(.zero))
        XCTAssertTrue(area.options.contains(.enabledDuringMouseDrag))
        XCTAssertFalse(area.options.contains(.inVisibleRect), "The page's clipped visible rect excludes the native titlebar")
        let close = try XCTUnwrap(fixture.window.standardWindowButton(.closeButton))
        let point = host.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), from: close)
        let hit = host.hitTest(point)
        XCTAssertTrue(hit === close || hit?.isDescendant(of: close) == true)
    }

    func testRegionUpdatesAfterPageResizeAndRemovesOldTrackingArea() throws {
        let fixture = makeFixture()
        defer { fixture.observer.stopObserving(); fixture.window.close() }
        let host = try XCTUnwrap(fixture.window.contentView?.superview)
        let first = try XCTUnwrap(fixture.observer.nativeTrackingArea)
        fixture.observer.refreshTrackingRegion()
        XCTAssertTrue(fixture.observer.nativeTrackingArea === first)
        fixture.observer.frame = NSRect(x: 180, y: 0, width: 150, height: 300)
        fixture.observer.refreshTrackingRegion()
        let changed = try XCTUnwrap(fixture.observer.nativeTrackingArea)
        XCTAssertFalse(changed === first)
        XCTAssertFalse(host.trackingAreas.contains { $0 === first })
        let region = host.convert(changed.rect, to: nil)
        XCTAssertEqual(region.minX, fixture.observer.convert(fixture.observer.bounds, to: nil).minX, accuracy: 0.01)
        XCTAssertEqual(region.width, 150, accuracy: 0.01)
        fixture.observer.frame.size.width = 0
        fixture.observer.refreshTrackingRegion()
        XCTAssertNil(fixture.observer.nativeTrackingArea)
        XCTAssertFalse(host.trackingAreas.contains { $0 === changed })
    }

    func testDetachMoveAndWindowCloseCleanUpTrackingAreas() async throws {
        let fixture = makeFixture()
        let firstHost = try XCTUnwrap(fixture.window.contentView?.superview)
        let firstArea = try XCTUnwrap(fixture.observer.nativeTrackingArea)
        fixture.observer.removeFromSuperview()
        XCTAssertNil(fixture.observer.nativeTrackingArea)
        XCTAssertFalse(firstHost.trackingAreas.contains { $0 === firstArea })
        let secondWindow = makeWindow()
        defer { fixture.observer.stopObserving(); fixture.window.close(); secondWindow.close() }
        secondWindow.contentView?.addSubview(fixture.observer)
        let secondArea = try XCTUnwrap(fixture.observer.nativeTrackingArea)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: fixture.window)
        XCTAssertTrue(fixture.observer.nativeTrackingArea === secondArea)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: secondWindow)
        XCTAssertNil(fixture.observer.nativeTrackingArea)
        await flushMainQueue()
        XCTAssertFalse(fixture.state.value)
    }

    func testDetachedObserverClearsHoverWithoutPolling() async {
        let state = HoverTestState()
        state.value = true
        let observer = TopbarHoverObserver.ObserverView(isHovered: Binding(get: { state.value }, set: { state.value = $0 }))
        observer.updateHover()
        observer.stopObserving()
        await flushMainQueue()
        XCTAssertFalse(state.value)
    }

    private func hovered(_ point: NSPoint, in region: NSRect) -> Bool {
        TopbarHoverGeometry.contains(point, region: region, appActive: true, windowVisible: true, miniaturized: false)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeFixture() -> (window: NSWindow, observer: TopbarHoverObserver.ObserverView, state: HoverTestState) {
        let window = makeWindow()
        let state = HoverTestState()
        let observer = TopbarHoverObserver.ObserverView(isHovered: Binding(get: { state.value }, set: { state.value = $0 }))
        observer.frame = NSRect(x: 120, y: 0, width: 240, height: 300)
        window.contentView?.addSubview(observer)
        return (window, observer, state)
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}

@MainActor
private final class HoverTestState { var value = false }
