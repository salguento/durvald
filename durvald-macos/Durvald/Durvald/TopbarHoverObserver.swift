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
            let contentRegion = content.convert(content.bounds, to: nil)
            let titlebar = NSRect(
                x: pageRegion.minX,
                y: window.contentLayoutRect.maxY,
                width: pageRegion.width,
                height: max(0, contentRegion.maxY - window.contentLayoutRect.maxY)
            )
            effect.frame = convert(titlebar, from: nil)
        }
    }
}

/// Observe the native titlebar without placing an overlay over its buttons.
struct TopbarHoverObserver: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(isHovered: $isHovered)
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.isHovered = $isHovered
        view.updateHover()
    }

    final class ObserverView: NSView {
        var isHovered: Binding<Bool>
        private var timer: Timer?

        init(isHovered: Binding<Bool>) {
            self.isHovered = isHovered
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            timer = nil
            guard window != nil else { return }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.updateHover() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func updateHover() {
            guard let window else { return }
            let point = window.mouseLocationOutsideOfEventStream
            let contentRegion = convert(bounds, to: nil)
            let topbar = NSRect(
                x: contentRegion.minX, y: window.contentLayoutRect.maxY,
                width: contentRegion.width,
                height: max(0, window.frame.height - window.contentLayoutRect.maxY)
            )
            let hovered = NSApp.isActive && window.isVisible && !window.isMiniaturized
                && topbar.contains(point)
            guard isHovered.wrappedValue != hovered else { return }
            DispatchQueue.main.async { [weak self] in self?.isHovered.wrappedValue = hovered }
        }

        deinit { timer?.invalidate() }
    }
}
