import AppKit
import SwiftUI

/// Keeps the metadata window inside the library window when resized or zoomed.
struct MetadataWindowBounds: NSViewRepresentable {
    var referenceWindow: NSWindow?

    func makeNSView(context: Context) -> MetadataWindowBoundsView {
        MetadataWindowBoundsView()
    }

    func updateNSView(_ nsView: MetadataWindowBoundsView, context: Context) {
        nsView.referenceWindow = referenceWindow
        nsView.updateBounds()
    }
}

final class MetadataWindowBoundsView: NSView {
    weak var referenceWindow: NSWindow?
    private var isUpdatingBounds = false
    private var isMaximized = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard window != nil else { return }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowGeometryChanged(_:)),
                                                   name: name, object: nil)
        }
        updateBounds()
    }

    @objc private func windowGeometryChanged(_ notification: Notification) {
        guard !isUpdatingBounds, let window,
              let changedWindow = notification.object as? NSWindow else { return }
        if changedWindow === window {
            if notification.name == NSWindow.didMoveNotification {
                guard isMaximized, NSEvent.pressedMouseButtons & 1 != 0 else { return }
                isMaximized = false
                isUpdatingBounds = true
                defer { isUpdatingBounds = false }
                var frame = window.frame
                // Keep the title area under the pointer as the window shrinks.
                let horizontalFraction = min(1, max(0, (NSEvent.mouseLocation.x - frame.minX) / frame.width))
                let restoredWidth = window.minSize.width
                frame.origin.x += (frame.width - restoredWidth) * horizontalFraction
                frame.size.width = restoredWidth
                window.setFrame(frame, display: true)
                return
            }
            if notification.name == NSWindow.didResizeNotification {
                isMaximized = window.frame.width >= window.maxSize.width - 1
                    && window.frame.height >= window.maxSize.height - 1
            }
        } else if changedWindow !== referenceWindow {
            return
        }
        updateBounds()
    }

    func updateBounds() {
        guard !isUpdatingBounds, let window,
              let referenceFrame = (referenceWindow !== window ? referenceWindow?.frame : nil)
                ?? window.screen?.visibleFrame else { return }
        isUpdatingBounds = true
        defer { isUpdatingBounds = false }

        let insetFrame = referenceFrame.insetBy(dx: 128, dy: 64)
        // Preserve the editor's minimum usable size on small library windows.
        let minimum = window.minSize
        let sizeLimit = NSSize(width: max(minimum.width, insetFrame.width),
                               height: max(minimum.height, insetFrame.height))
        window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
        window.collectionBehavior.insert(.fullScreenNone)
        window.maxSize = sizeLimit
        var frame = window.frame
        frame.size.width = min(frame.width, sizeLimit.width)
        frame.size.height = min(frame.height, sizeLimit.height)
        let minX = insetFrame.width >= frame.width ? insetFrame.minX : referenceFrame.midX - frame.width / 2
        let minY = insetFrame.height >= frame.height ? insetFrame.minY : referenceFrame.midY - frame.height / 2
        frame.origin.x = max(minX, min(frame.minX, max(minX, insetFrame.maxX - frame.width)))
        frame.origin.y = max(minY, min(frame.minY, max(minY, insetFrame.maxY - frame.height)))
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

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
            guard self != nil, event.window === observedWindow, event.keyCode == 53,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  observedWindow?.attachedSheet == nil,
                  !(observedWindow?.firstResponder is NSTextView) else { return event }
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
