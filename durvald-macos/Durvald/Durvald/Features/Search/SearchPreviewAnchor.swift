import AppKit
import SwiftUI

/// A child panel can extend below the native toolbar without being clipped to
/// the toolbar item's bounds or taking the field editor's keyboard focus.
struct SearchPreviewAnchor<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let contentHeight: CGFloat
    let onDismiss: () -> Void
    let onKey: (UInt16) -> Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onLayout = { [weak coordinator = context.coordinator] in coordinator?.updatePosition() }
        context.coordinator.anchor = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.host.rootView = AnyView(content())
        coordinator.updatePosition()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        view.onLayout = nil
        coordinator.teardown()
    }

    final class AnchorView: NSView {
        var onLayout: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); onLayout?() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onLayout?() }
    }

    final class PreviewPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    @MainActor
    final class Coordinator {
        var parent: SearchPreviewAnchor
        weak var anchor: AnchorView?
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        private let panel: PreviewPanel
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?

        init(parent: SearchPreviewAnchor) {
            self.parent = parent
            panel = PreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.contentView = host
        }

        func updatePosition() {
            guard parent.isPresented, let anchor, let window = anchor.window,
                  window.isKeyWindow else { hide(); return }
            observe(window)
            let field = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? field
            let width = min(420, max(300, field.width), screen.width - 24)
            let x = min(screen.maxX - width - 12, max(screen.minX + 12, field.midX - width / 2))
            let height = min(620, max(24, parent.contentHeight),
                             max(24, field.minY - screen.minY - 16))
            panel.setFrame(NSRect(x: x, y: field.minY - height - 6, width: width, height: height), display: true)
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
            installMonitor()
        }

        private func observe(_ window: NSWindow) {
            guard observedWindow !== window else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            observedWindow = window
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated { self?.updatePosition() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                      object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated {
                    self?.parent.onDismiss()
                    self?.hide()
                }
            })
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
                [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.panel.isVisible, let anchor = self.anchor,
                          let window = anchor.window else { return event }
                    if event.type == .keyDown, event.window === window,
                       event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                       self.parent.onKey(event.keyCode) { return nil }
                    if event.type == .leftMouseDown || event.type == .rightMouseDown {
                        if event.window === self.panel { return event }
                        let field = anchor.convert(anchor.bounds, to: nil)
                        if event.window !== window || !field.contains(event.locationInWindow) {
                            self.parent.onDismiss()
                            self.hide()
                        }
                    }
                    return event
                }
            }
        }

        private func hide() {
            panel.orderOut(nil)
            panel.parent?.removeChildWindow(panel)
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }

        func teardown() {
            hide()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            host.rootView = AnyView(EmptyView())
        }
    }
}
