import AppKit
import SwiftUI

/// Removes the standard macOS window controls after SwiftUI attaches the
/// content to its native window. The window remains movable and closable by
/// the commands exposed by its content.
struct WindowTrafficLightsHider: NSViewRepresentable {
    var closesOnEscape = false

    func makeNSView(context: Context) -> NSView {
        WindowObserverView(closesOnEscape: closesOnEscape)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let observer = nsView as? WindowObserverView else { return }
        observer.closesOnEscape = closesOnEscape
        observer.configureWindow()
    }
}

private final class WindowObserverView: NSView {
    var closesOnEscape: Bool {
        didSet { configureEscapeMonitor() }
    }
    private var escapeMonitor: Any?

    init(closesOnEscape: Bool) {
        self.closesOnEscape = closesOnEscape
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { removeEscapeMonitor() }
        super.viewWillMove(toWindow: newWindow)
    }

    func configureWindow() {
        guard let window else { return }
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        configureEscapeMonitor()
    }

    private func configureEscapeMonitor() {
        removeEscapeMonitor()
        guard closesOnEscape, let observedWindow = window else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak observedWindow] event in
            guard self != nil, event.window === observedWindow, event.keyCode == 53 else { return event }
            observedWindow?.performClose(nil)
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    deinit {
        removeEscapeMonitor()
    }
}
