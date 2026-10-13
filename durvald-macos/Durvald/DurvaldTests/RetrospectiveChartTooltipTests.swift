import AppKit
import SwiftUI
import XCTest
@testable import Durvald

@MainActor
final class RetrospectiveChartTooltipTests: XCTestCase {
    func testRenderedChartCreatesTooltipRegionsForBothBarsOfEveryDay() throws {
        let days = (0..<7).map {
            RetrospectiveWeekSnapshot.Day(date: Date(timeIntervalSince1970: 1_791_158_400 + Double($0) * 86_400),
                                    current: $0 + 1, previous: 7 - $0)
        }
        let snapshot = RetrospectiveWeekSnapshot(days: days, currentTotal: 28, previousTotal: 28)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ScrollView {
            VStack(spacing: 0) {
                RetrospectiveOverviewHeader(snapshot: snapshot)
                Color.clear.frame(height: 500)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }.scrollEdgeEffectStyle(.soft, for: [.top, .bottom]))
        window.contentView = host
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        func tooltipViews(in view: NSView) -> [RetrospectiveChartTooltipView] {
            let own = (view as? RetrospectiveChartTooltipView).map { [$0] } ?? []
            return own + view.subviews.flatMap { tooltipViews(in: $0) }
        }
        let tooltip = try XCTUnwrap(tooltipViews(in: host).first(where: { !$0.tooltipViews.isEmpty }))
        XCTAssertEqual(tooltip.tooltipViews.count, 14,
                       "Test the real ChartProxy/representable layout, not only a standalone native view")
        XCTAssertGreaterThan(tooltip.bounds.width, 0)
        XCTAssertGreaterThan(tooltip.bounds.height, 0)
        XCTAssertEqual(tooltip.tooltipViews.map(\.hoverText).filter { $0.contains("Esta semana") }.count, 7)
        XCTAssertEqual(tooltip.tooltipViews.map(\.hoverText).filter { $0.contains("Semana passada") }.count, 7)
        for bar in tooltip.tooltipViews {
            XCTAssertTrue(bar.clipsToBounds)
            XCTAssertEqual(bar.visibleRect, bar.bounds,
                           "Native tooltip tracking must be clipped to its bar, not the entire window")
        }
        XCTAssertTrue(tooltip.tooltipViews.allSatisfy { $0.toolTip == nil })
        let region = try XCTUnwrap(tooltip.regions.first)
        let center = CGPoint(x: region.frame.midX, y: region.frame.midY)
        let pointInParent = tooltip.convert(center, to: tooltip.superview)
        XCTAssertTrue(tooltip.hitTest(pointInParent) === tooltip.tooltipViews.first)
        let pointInWindow = tooltip.convert(center, to: host.superview)
        XCTAssertTrue(host.hitTest(pointInWindow) === tooltip.tooltipViews.first,
                      "The actual hosting hierarchy must route the mouse to the tooltip owner")
    }

    func testIndividualBarsRegisterDistinctPopoverValues() {
        let view = RetrospectiveChartTooltipView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.setRegions([
            .init(frame: CGRect(x: 20, y: 40, width: 20, height: 60), text: "Segunda-feira · Esta semana\n3 músicas"),
            .init(frame: CGRect(x: 40, y: 20, width: 20, height: 80), text: "Segunda-feira · Semana passada\n4 músicas")
        ])
        XCTAssertEqual(view.tooltipViews.count, 2)
        XCTAssertEqual(Set(view.tooltipViews.map(\.hoverText)),
                       ["Segunda-feira · Esta semana\n3 músicas", "Segunda-feira · Semana passada\n4 músicas"])
        XCTAssertTrue(view.isFlipped, "Native tracking must use the chart's top-down coordinates")
        XCTAssertTrue(view.hitTest(CGPoint(x: 30, y: 60)) === view.tooltipViews.first,
                      "The tooltip owner must remain the native mouse target over a bar")
        XCTAssertNil(view.hitTest(CGPoint(x: 80, y: 60)), "Empty chart space must not capture the mouse")
        let views = view.tooltipViews.map(ObjectIdentifier.init)
        view.setFrameSize(view.frame.size)
        XCTAssertEqual(view.tooltipViews.map(ObjectIdentifier.init), views,
                       "An unchanged frame must not reset the popover hover delay")
    }

    func testHoverPresentsSharedCollectionPopoverAndExitClosesIt() async throws {
        let window = KeyHoverTestWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let bar = RetrospectiveChartBarHoverView(frame: CGRect(x: 40, y: 20, width: 30, height: 80),
                                          text: "Segunda-feira · Esta semana\n3 músicas")
        bar.clipsToBounds = true
        window.contentView?.addSubview(bar)
        window.makeKeyAndOrderFront(nil)
        defer { bar.cancelHover(); window.close() }
        XCTAssertTrue(window.isKeyWindow)
        bar.mouseEntered(with: NSEvent())
        try await Task.sleep(for: .milliseconds(350))
        let popover = try XCTUnwrap(bar.popover)
        XCTAssertTrue(popover.isShown)
        XCTAssertTrue(popover.contentViewController is NSHostingController<CollectionHoverDetails>)
        bar.mouseExited(with: NSEvent())
        XCTAssertFalse(popover.isShown)
        XCTAssertNil(bar.popover)
    }

    func testLeavingBarCancelsPendingPopover() async throws {
        let bar = RetrospectiveChartBarHoverView(frame: CGRect(x: 0, y: 0, width: 20, height: 80),
                                          text: "Segunda-feira · Esta semana\n3 músicas")
        bar.mouseEntered(with: NSEvent())
        XCTAssertTrue(bar.isHovering)
        bar.mouseExited(with: NSEvent())
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(bar.isHovering)
        XCTAssertNil(bar.popover, "Leaving a bar must cancel its delayed popover")
    }

    func testChangingDataAndResizingReplacesRegionsAndLeavingChartClearsThem() {
        let view = RetrospectiveChartTooltipView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        view.setRegions([.init(frame: CGRect(x: 100, y: 20, width: 20, height: 80), text: "3 músicas")])
        XCTAssertEqual(view.tooltipViews.map(\.hoverText), ["3 músicas"])
        view.setRegions([.init(frame: CGRect(x: 100, y: 30, width: 20, height: 70), text: "7 músicas")])
        XCTAssertEqual(view.tooltipViews.map(\.hoverText), ["7 músicas"])
        view.setFrameSize(CGSize(width: 80, height: 100))
        XCTAssertTrue(view.tooltipViews.isEmpty, "Regions outside the visible chart must not remain active")
        view.setFrameSize(CGSize(width: 200, height: 100))
        XCTAssertEqual(view.tooltipViews.map(\.hoverText), ["7 músicas"])
        view.setRegions([])
        XCTAssertTrue(view.tooltipViews.isEmpty)
    }
}

/// Unit tests need a deterministic key-window state while Xcode owns focus.
@MainActor
private final class KeyHoverTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
