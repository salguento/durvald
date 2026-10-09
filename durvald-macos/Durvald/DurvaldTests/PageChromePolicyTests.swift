import AppKit
import SwiftUI
import XCTest
@testable import Durvald

@MainActor
final class PageChromePolicyTests: XCTestCase {
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
                    XCTAssertEqual(policy.globalSearchOffset, queue ? -150 : 0)
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
            XCTAssertEqual(top.canvasSafeAreaEdges, .horizontal)
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

    func testArtistViewportExpandsArtworkOnlyLeftAndScrollerAcrossBothPanels() {
        let viewport = PageViewport(visibleFrame: CGRect(x: 220, y: 80, width: 600, height: 400),
                                    canvasFrame: CGRect(x: 0, y: 0, width: 1120, height: 500))
        XCTAssertEqual(viewport.visibleWidth, 600)
        XCTAssertEqual(viewport.leadingInset, 220)
        XCTAssertEqual(viewport.trailingInset, 300)
        XCTAssertEqual(viewport.leadingExpandedWidth, 820)
        XCTAssertEqual(viewport.fullWidth, 1120)
        XCTAssertEqual(viewport.sideInsets.top, 0)
        XCTAssertEqual(viewport.sideInsets.bottom, 0)
        XCTAssertEqual(viewport.leadingInset + viewport.visibleWidth / 2, 520,
                       "The title stays centered in the visible column")
    }

    func testViewportDoesNotInventSideMarginsOrMirrorTrailingPanel() {
        let visible = CGRect(x: 100, y: 0, width: 600, height: 400)
        let same = PageViewport(visibleFrame: visible, canvasFrame: visible)
        XCTAssertEqual(same.leadingInset, 0)
        XCTAssertEqual(same.trailingInset, 0)
        let queueOnly = PageViewport(visibleFrame: visible,
            canvasFrame: CGRect(x: 100, y: 0, width: 900, height: 400))
        XCTAssertEqual(queueOnly.leadingExpandedWidth, 600)
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

    func testNativeMeasurementFollowsResizeWithoutControllingCompactDecision() {
        let layout = PageToolbarLayout(kind: .standard, queuePresented: false, expandedMinimumWidth: 400)
        let measure = PageToolbarMeasurement(availableWidth: 500, detailWidth: 900)
        XCTAssertEqual(layout.preferredWidth(detailWidth: 1020, sidebarVisible: true, measurement: measure), 620)
        XCTAssertTrue(layout.controls(assignedWidth: 300).compact)
        XCTAssertFalse(layout.controls(assignedWidth: 700).compact)
    }

    func testSidebarFallbackAndArtistMinimumReserveTheirDifferentControls() {
        let standard = PageToolbarLayout(kind: .standard, queuePresented: false, expandedMinimumWidth: 400)
        let shown = standard.preferredWidth(detailWidth: 900, sidebarVisible: true, measurement: nil)
        let hidden = standard.preferredWidth(detailWidth: 900, sidebarVisible: false, measurement: nil)
        XCTAssertEqual(shown - hidden, 204)
        let artist = PageToolbarLayout(kind: .artist, queuePresented: true, expandedMinimumWidth: 308)
        XCTAssertEqual(artist.minimumWidth, 370)
        XCTAssertEqual(artist.preferredWidth(detailWidth: 100, sidebarVisible: false, measurement: nil), 370)
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
}
