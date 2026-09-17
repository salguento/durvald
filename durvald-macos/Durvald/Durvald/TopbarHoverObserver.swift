import AppKit
import SwiftUI

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
            let topbar = NSRect(
                x: 0, y: window.contentLayoutRect.maxY,
                width: window.frame.width,
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
