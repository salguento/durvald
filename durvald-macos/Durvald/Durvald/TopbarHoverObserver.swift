import AppKit
import SwiftUI

/// A native header material constrained to the page's portion of the titlebar.
/// Its placement comes from the window, independent of scroll-view discovery.
struct PageTopbarBackground: NSViewRepresentable {
    let isVisible: Bool

    func makeNSView(context: Context) -> BackgroundView {
        BackgroundView()
    }

    func updateNSView(_ view: BackgroundView, context: Context) {
        view.effect.isHidden = !isVisible
        view.needsLayout = true
    }

    final class BackgroundView: NSView {
        let effect = NSVisualEffectView()

        override init(frame: NSRect) {
            super.init(frame: frame)
            clipsToBounds = true
            effect.material = .headerView
            effect.blendingMode = .withinWindow
            effect.state = .followsWindowActiveState
            addSubview(effect)
        }

        convenience init() { self.init(frame: .zero) }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard let window, let content = window.contentView else { return }
            let pageRegion = convert(bounds, to: nil)
            let host = content.superview ?? content
            let frameRegion = host.convert(host.bounds, to: nil)
            let titlebar = TopbarHoverGeometry.region(page: pageRegion, layout: window.contentLayoutRect,
                                                      frame: frameRegion)
            effect.frame = convert(titlebar, from: nil)
        }
    }
}

/// The native frame includes the titlebar even when the page view itself is
/// clipped below it. Crop horizontally to the page, excluding sidebar/queue.
enum TopbarHoverGeometry {
    static func region(page: NSRect, layout: NSRect, frame: NSRect) -> NSRect {
        let titlebar = NSRect(x: frame.minX, y: layout.maxY, width: frame.width,
                              height: max(0, frame.maxY - layout.maxY))
        let pageStrip = NSRect(x: page.minX, y: titlebar.minY, width: page.width, height: titlebar.height)
        let clipped = titlebar.intersection(pageStrip)
        return clipped.isEmpty ? .zero : clipped
    }

    static func contains(_ point: NSPoint, region: NSRect, appActive: Bool,
                         windowVisible: Bool, miniaturized: Bool) -> Bool {
        appActive && windowVisible && !miniaturized && !region.isEmpty && region.contains(point)
    }
}

/// Track the real native titlebar region without adding a hit-test overlay.
struct TopbarHoverObserver: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(isHovered: $isHovered)
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.isHovered = $isHovered
        view.refreshTrackingRegion()
        view.updateHover()
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObserverView: NSView {
        var isHovered: Binding<Bool>
        private(set) var nativeTrackingArea: NSTrackingArea?
        private weak var trackingHost: NSView?
        private var notifications: [NSObjectProtocol] = []
        private var isObserving = false
        private var pendingHover: Bool?
        private var publicationRevision: UInt64 = 0

        init(isHovered: Binding<Bool>) {
            self.isHovered = isHovered
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            isObserving = true
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification] {
                notifications.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.refreshTrackingRegion()
                        self?.updateHover()
                    }
                })
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateHover() }
                })
            }
            notifications.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopObserving() }
            })
            refreshTrackingRegion()
            updateHover()
        }

        override func layout() {
            super.layout()
            refreshTrackingRegion()
            updateHover()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            refreshTrackingRegion()
            updateHover()
        }

        override func mouseEntered(with event: NSEvent) { updateHover(at: event.locationInWindow) }
        override func mouseExited(with event: NSEvent) { publishHover(false) }
        override func mouseMoved(with event: NSEvent) { updateHover(at: event.locationInWindow) }

        func refreshTrackingRegion() {
            guard isObserving, let window, let host = window.contentView?.superview else {
                removeNativeTrackingArea()
                return
            }
            let region = TopbarHoverGeometry.region(page: convert(bounds, to: nil), layout: window.contentLayoutRect,
                                                    frame: host.convert(host.bounds, to: nil))
            let rect = host.convert(region, from: nil)
            guard !region.isEmpty else { removeNativeTrackingArea(); return }
            if trackingHost === host, nativeTrackingArea?.rect == rect { return }
            removeNativeTrackingArea()
            let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .enabledDuringMouseDrag],
                                      owner: self, userInfo: nil)
            host.addTrackingArea(area)
            trackingHost = host
            nativeTrackingArea = area
        }

        func updateHover(at point: NSPoint? = nil) {
            guard isObserving, let window, let host = trackingHost, let area = nativeTrackingArea else {
                publishHover(false)
                return
            }
            let hovered = TopbarHoverGeometry.contains(point ?? window.mouseLocationOutsideOfEventStream,
                region: host.convert(area.rect, to: nil), appActive: NSApp.isActive,
                windowVisible: window.isVisible, miniaturized: window.isMiniaturized)
            publishHover(hovered)
        }

        private func publishHover(_ hovered: Bool) {
            guard pendingHover != hovered else { return }
            publicationRevision &+= 1
            let revision = publicationRevision
            guard isHovered.wrappedValue != hovered else { pendingHover = nil; return }
            pendingHover = hovered
            // Defer binding writes out of representable/layout updates, while
            // invalidating older queued publications on region/lifecycle changes.
            DispatchQueue.main.async { [weak self] in
                guard let self, publicationRevision == revision else { return }
                pendingHover = nil
                if isHovered.wrappedValue != hovered { isHovered.wrappedValue = hovered }
            }
        }

        func stopObserving() {
            isObserving = false
            notifications.forEach { NotificationCenter.default.removeObserver($0) }
            notifications.removeAll()
            removeNativeTrackingArea()
            publishHover(false)
        }

        private func removeNativeTrackingArea() {
            if let area = nativeTrackingArea { trackingHost?.removeTrackingArea(area) }
            nativeTrackingArea = nil
            trackingHost = nil
        }

        deinit {
            notifications.forEach { NotificationCenter.default.removeObserver($0) }
            if let area = nativeTrackingArea, let host = trackingHost {
                MainActor.assumeIsolated { host.removeTrackingArea(area) }
            }
        }
    }
}
