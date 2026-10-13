import AppKit
import SwiftUI

struct RetrospectiveChartTooltipRegion: Equatable {
    let frame: CGRect
    let text: String
}

/// Native tracking keeps each bar's hover independent inside the chart's scroll view.
struct RetrospectiveChartTooltips: NSViewRepresentable {
    let regions: [RetrospectiveChartTooltipRegion]

    func makeNSView(context: Context) -> RetrospectiveChartTooltipView {
        RetrospectiveChartTooltipView(frame: .zero)
    }

    func updateNSView(_ view: RetrospectiveChartTooltipView, context: Context) {
        view.setRegions(regions)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RetrospectiveChartTooltipView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    static func dismantleNSView(_ view: RetrospectiveChartTooltipView, coordinator: ()) {
        view.setRegions([])
    }
}

@MainActor
final class RetrospectiveChartTooltipView: NSView {
    private(set) var regions: [RetrospectiveChartTooltipRegion] = []
    private(set) var tooltipViews: [RetrospectiveChartBarHoverView] = []

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        nextResponder?.mouseDown(with: event)
    }

    func setRegions(_ newRegions: [RetrospectiveChartTooltipRegion]) {
        guard regions != newRegions else { return }
        regions = newRegions
        registerTooltips()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        // Re-registering unchanged rectangles resets the native hover delay.
        if changed { registerTooltips() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerTooltips()
    }

    private func registerTooltips() {
        for view in tooltipViews {
            view.cancelHover()
            view.removeFromSuperview()
        }
        tooltipViews.removeAll(keepingCapacity: true)
        for region in regions {
            let rect = region.frame.intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { continue }
            let bar = RetrospectiveChartBarHoverView(frame: rect, text: region.text)
            // Keep the tracking area restricted to this individual bar.
            bar.clipsToBounds = true
            addSubview(bar)
            tooltipViews.append(bar)
        }
    }
}

@MainActor
final class RetrospectiveChartBarHoverView: NSView {
    let hoverText: String
    private(set) var isHovering = false
    private(set) var popover: NSPopover?
    private var pendingHover: Task<Void, Never>?
    private var hoverArea: NSTrackingArea?

    init(frame: CGRect, text: String) {
        hoverText = text
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        cancelHover()
        isHovering = true
        pendingHover = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled, self.isHovering,
                  self.window?.isKeyWindow == true, !self.visibleRect.isEmpty else { return }
            let lines = self.hoverText.split(separator: "\n", maxSplits: 1).map(String.init)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = NSHostingController(rootView:
                CollectionHoverDetails(title: lines.first ?? self.hoverText,
                                       subtitle: lines.count > 1 ? lines[1] : nil))
            self.popover = popover
            popover.show(relativeTo: self.bounds, of: self, preferredEdge: .maxY)
            self.pendingHover = nil
        }
    }

    override func mouseExited(with event: NSEvent) { cancelHover() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelHover() }
    }

    override func scrollWheel(with event: NSEvent) {
        cancelHover()
        nextResponder?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        cancelHover()
        nextResponder?.mouseDown(with: event)
    }

    func cancelHover() {
        isHovering = false
        pendingHover?.cancel()
        pendingHover = nil
        popover?.close()
        popover = nil
    }
}
