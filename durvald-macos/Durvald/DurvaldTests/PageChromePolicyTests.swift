import AppKit
import SwiftUI
import XCTest
@testable import Durvald

@MainActor
final class PageChromePolicyTests: XCTestCase {
    func testRetrospectiveAccessoryUsesNativeToolbarWithEitherQueueState() {
        for queue in [false, true] {
            let policy = PageChromePolicy(kind: .standard, queuePresented: queue,
                                          hasSupplementaryHeader: true)
            XCTAssertFalse(policy.usesPageBackdrop)
            XCTAssertEqual(policy.toolbarVisibility, .automatic,
                           "History must use the native toolbar surface with its accessory")
        }
    }

    func testStandardPageUsesAutomaticMaterialUnlessQueueNeedsLocalBackdrop() {
        for queue in [false, true] {
            for scrolled in [false, true] {
                for hovered in [false, true] {
                    let policy = PageChromePolicy(kind: .standard, queuePresented: queue,
                                                  scrolled: scrolled, hovered: hovered)
                    XCTAssertEqual(policy.toolbarVisibility, queue ? .hidden : .automatic)
                    XCTAssertEqual(policy.usesPageBackdrop, queue)
                    XCTAssertEqual(policy.observesHover, queue)
                    XCTAssertEqual(policy.backdropVisible, scrolled || hovered)
                    XCTAssertEqual(policy.queueReservation, queue ? 300 : 0)
                }
            }
        }
    }

    func testArtistKeepsScrollPrecedenceAndExplicitSafeAreaException() {
        for queue in [false, true] {
            let top = PageChromePolicy(kind: .artist, queuePresented: queue)
            let hover = PageChromePolicy(kind: .artist, queuePresented: queue, hovered: true)
            let scroll = PageChromePolicy(kind: .artist, queuePresented: queue, scrolled: true, hovered: true)
            XCTAssertEqual(top.toolbarVisibility, .hidden)
            XCTAssertEqual(hover.toolbarVisibility, .visible)
            XCTAssertEqual(scroll.toolbarVisibility, .automatic)
            XCTAssertTrue(top.observesHover)
            XCTAssertFalse(top.usesPageBackdrop)
            XCTAssertTrue(top.hidesTopScrollEdge)
            XCTAssertFalse(hover.hidesTopScrollEdge)
            XCTAssertEqual(top.visibleSafeAreaEdges, [.top, .bottom])
            XCTAssertEqual(top.canvasSafeAreaEdges, [])
        }
        let standard = PageChromePolicy(kind: .standard, queuePresented: false)
        XCTAssertEqual(standard.visibleSafeAreaEdges, [])
        XCTAssertEqual(standard.canvasSafeAreaEdges, [])
    }

    func testScrollToleranceMatchesSavedAndInsetAdjustedOffsets() {
        for offset: CGFloat in [-60, 0, 0.5, 1] {
            XCTAssertFalse(PageChromePolicy.isScrolled(offset: offset))
        }
        XCTAssertTrue(PageChromePolicy.isScrolled(offset: 1.01))
        XCTAssertFalse(PageChromePolicy.isScrolled(offset: -60 + 60))
        XCTAssertTrue(PageChromePolicy.isScrolled(offset: -58 + 60))
    }

    func testArtistViewportLimitsArtworkToVisibleColumnForBothPanels() {
        for queueWidth: CGFloat in [0, 300] {
            let availableWidth: CGFloat = 1120 - 220 - queueWidth
            let visible = CGRect(x: 220, y: 80, width: availableWidth, height: 400)
            let viewport = PageViewport(visibleFrame: visible, canvasFrame: visible)
            XCTAssertEqual(viewport.visibleWidth, availableWidth)
            XCTAssertEqual(viewport.leadingInset, 0)
            XCTAssertEqual(viewport.trailingInset, 0)
            XCTAssertEqual(viewport.expandedWidth, availableWidth)
            XCTAssertEqual(viewport.fullWidth, availableWidth)
            XCTAssertEqual(viewport.sideInsets.top, 0)
            XCTAssertEqual(viewport.sideInsets.bottom, 0)
        }
    }

    func testViewportDoesNotInventSideMarginsOrMirrorTrailingPanel() {
        let visible = CGRect(x: 100, y: 0, width: 600, height: 400)
        let same = PageViewport(visibleFrame: visible, canvasFrame: visible)
        XCTAssertEqual(same.leadingInset, 0)
        XCTAssertEqual(same.trailingInset, 0)
        let queueOnly = PageViewport(visibleFrame: visible,
            canvasFrame: CGRect(x: 100, y: 0, width: 900, height: 400))
        XCTAssertEqual(queueOnly.visibleWidth, 600)
        XCTAssertEqual(queueOnly.trailingInset, 300)
        let clipped = PageViewport(visibleFrame: visible,
            canvasFrame: CGRect(x: 120, y: 0, width: 500, height: 400))
        XCTAssertEqual(clipped.leadingInset, 0)
        XCTAssertEqual(clipped.trailingInset, 0)
        XCTAssertEqual(clipped.expandedWidth, 600, "A clipped canvas during resize must not narrow visible content")
    }

    func testMeasuredDetailWidthDoesNotReserveQueueTwice() {
        let fallback = PageViewport.column(visibleWidth: 600, measuredFullWidth: 0, trailingReservation: 300)
        XCTAssertEqual(fallback.fullWidth, 900)
        let measured = PageViewport.column(visibleWidth: 600, measuredFullWidth: 900, trailingReservation: 300)
        XCTAssertEqual(measured.fullWidth, 900)
        XCTAssertEqual(measured.trailingInset, 300)
        XCTAssertEqual(PageViewport.column(visibleWidth: 600, measuredFullWidth: 0,
                                           trailingReservation: 0).fullWidth, 600)
    }

    func testCompactnessUsesAssignedWidthAfterQueueReservation() {
        for kind in [PageChromePolicy.Kind.standard, .artist] {
            for queue in [false, true] {
                let layout = PageToolbarLayout(kind: kind, queuePresented: queue, expandedMinimumWidth: 400)
                let boundary = 400 + layout.panelReservation
                XCTAssertTrue(layout.controls(assignedWidth: boundary - 1).compact)
                XCTAssertFalse(layout.controls(assignedWidth: boundary).compact)
                for width: CGFloat in [0, 36, 80, 300, 700, 1600] {
                    let controls = layout.controls(assignedWidth: width)
                    XCTAssertGreaterThanOrEqual(controls.summaryWidth, 0)
                    XCTAssertGreaterThanOrEqual(controls.searchWidth, 36)
                    XCTAssertLessThanOrEqual(controls.searchWidth, 220)
                }
            }
        }
    }

    func testContentColumnWidthFollowsResizeWithoutControllingCompactDecision() {
        let layout = PageToolbarLayout(kind: .standard, queuePresented: false, expandedMinimumWidth: 400)
        let initial = layout.preferredWidth(detailWidth: 900, sidebarVisible: true)
        XCTAssertEqual(layout.preferredWidth(detailWidth: 1020, sidebarVisible: true) - initial, 120)
        XCTAssertTrue(layout.controls(assignedWidth: 300).compact)
        XCTAssertFalse(layout.controls(assignedWidth: 700).compact)
    }

    func testExpandedCompactSearchReservesItsActualWidthWithoutHidingSummary() {
        let layout = PageToolbarLayout(kind: .standard, queuePresented: false, expandedMinimumWidth: 400)
        let collapsed = layout.controls(assignedWidth: 360)
        let expanded = layout.controls(assignedWidth: 360, searchExpanded: true)
        XCTAssertTrue(expanded.compact)
        XCTAssertEqual(expanded.searchWidth, 220)
        XCTAssertEqual(expanded.summaryWidth, 80)
        XCTAssertEqual(collapsed.summaryWidth - expanded.summaryWidth, 220 - 36)
    }

    func testSidebarFallbackAndArtistMinimumReserveTheirDifferentControls() {
        let standard = PageToolbarLayout(kind: .standard, queuePresented: false, expandedMinimumWidth: 400)
        let shown = standard.preferredWidth(detailWidth: 900, sidebarVisible: true)
        let hidden = standard.preferredWidth(detailWidth: 900, sidebarVisible: false)
        XCTAssertEqual(shown - hidden, 204)
        let artist = PageToolbarLayout(kind: .artist, queuePresented: true, expandedMinimumWidth: 308)
        XCTAssertEqual(artist.minimumWidth, 378)
        XCTAssertEqual(artist.preferredWidth(detailWidth: 100, sidebarVisible: false), 378)
    }

    func testNativeMaterialAndHoverShareRegionBeforeAndAfterResize() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try XCTUnwrap(window.contentView)
        let background = PageTopbarBackground.BackgroundView(frame: NSRect(x: 220, y: 0, width: 380, height: content.bounds.height))
        let observer = TopbarHoverObserver.ObserverView(isHovered: .constant(false))
        observer.frame = background.frame
        content.addSubview(background)
        content.addSubview(observer)
        defer { observer.stopObserving(); window.close() }
        let host = try XCTUnwrap(content.superview)
        for width: CGFloat in [380, 220] {
            background.frame.size.width = width
            observer.frame.size.width = width
            background.needsLayout = true
            background.layoutSubtreeIfNeeded()
            observer.refreshTrackingRegion()
            let tracking = try XCTUnwrap(observer.nativeTrackingArea)
            let material = background.convert(background.effect.frame, to: nil)
            let hover = host.convert(tracking.rect, to: nil)
            XCTAssertEqual(material, hover)
            XCTAssertFalse(material.isEmpty)
            XCTAssertTrue(background.bounds.contains(background.effect.frame))
            XCTAssertEqual(material.width, width, accuracy: 0.01)
            XCTAssertNil(background.hitTest(.zero))
        }
    }

    func testRetrospectiveAccessoryFollowsContentColumnAndDetachesOnLeavingPage() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let anchor = RetrospectiveToolbarAccessoryAnchor(height: 46, content: AnyView(Text("Picker")))
        anchor.frame = NSRect(x: 220, y: 0, width: 380, height: 200)
        content.addSubview(anchor)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.first === anchor.accessory)
        for width: CGFloat in [380, 220] {
            anchor.frame.size.width = width
            anchor.accessory.view.layoutSubtreeIfNeeded()
            anchor.updatePlacement()
            let controls = anchor.host.convert(anchor.host.bounds, to: nil)
            let page = anchor.convert(anchor.bounds, to: nil)
            XCTAssertEqual(controls.minX, page.minX, accuracy: 0.01)
            XCTAssertEqual(controls.width, width, accuracy: 0.01)
            XCTAssertEqual(controls.height, 46, accuracy: 0.01)
        }
        anchor.removeFromSuperview()
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty,
                      "The picker must not remain in the toolbar after leaving history")
    }

    func testRetrospectivePickerContentUpdatesDoNotResizeWindowOrAccessory() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let anchor = RetrospectiveToolbarAccessoryAnchor(height: 46, content: AnyView(Text("Geral")))
        anchor.frame = NSRect(x: 220, y: 0, width: 380, height: 200)
        content.addSubview(anchor)
        let originalFrame = window.frame
        let originalMinimum = window.contentMinSize
        for title in ["Artistas", "Álbuns", "Faixas", "Geral"] {
            anchor.host.rootView = AnyView(Text(title)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            anchor.accessory.view.layoutSubtreeIfNeeded()
            anchor.updatePlacement()
            XCTAssertTrue(anchor.host.sizingOptions.isEmpty,
                          "The picker must not contribute sizing constraints to the titlebar")
            XCTAssertEqual(window.frame, originalFrame)
            XCTAssertEqual(window.contentMinSize, originalMinimum)
            XCTAssertEqual(anchor.accessory.view.frame.height, 46, accuracy: 0.01)
            XCTAssertEqual(anchor.host.frame.height, 46, accuracy: 0.01)
            XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
            XCTAssertTrue(window.titlebarAccessoryViewControllers.first === anchor.accessory)
        }
    }
}
