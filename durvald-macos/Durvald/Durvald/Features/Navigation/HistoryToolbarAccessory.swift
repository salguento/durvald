import AppKit
import SwiftUI

/// Lets the window extend its own toolbar surface below the toolbar controls.
struct HistoryToolbarAccessory<Content: View>: NSViewRepresentable {
    let content: Content
    let height: CGFloat

    init(height: CGFloat, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    func makeNSView(context: Context) -> HistoryToolbarAccessoryAnchor {
        HistoryToolbarAccessoryAnchor(height: height, content: hostedContent(context.environment))
    }

    func updateNSView(_ view: HistoryToolbarAccessoryAnchor, context: Context) {
        view.host.rootView = hostedContent(context.environment)
        view.updatePlacement()
    }

    static func dismantleNSView(_ view: HistoryToolbarAccessoryAnchor, coordinator: ()) {
        view.detach()
        view.host.rootView = AnyView(EmptyView())
    }

    private func hostedContent(_ environment: EnvironmentValues) -> AnyView {
        AnyView(content.environment(\.self, environment))
    }
}

@MainActor
final class HistoryToolbarAccessoryAnchor: NSView {
    let accessory = NSTitlebarAccessoryViewController()
    let host: NSHostingView<AnyView>
    private weak var attachedWindow: NSWindow?
    private let pane: HistoryToolbarAccessoryPane

    init(height: CGFloat, content: AnyView) {
        host = NSHostingView(rootView: content)
        pane = HistoryToolbarAccessoryPane(frame: NSRect(x: 0, y: 0, width: 1, height: height))
        super.init(frame: .zero)
        pane.addSubview(host)
        pane.onLayout = { [weak self] in self?.updatePlacement() }
        accessory.layoutAttribute = .bottom
        accessory.automaticallyAdjustsSize = false
        accessory.fullScreenMinHeight = height
        accessory.view = pane
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard attachedWindow !== window else { return }
        detach()
        guard let window else { return }
        attachedWindow = window
        window.addTitlebarAccessoryViewController(accessory)
        updatePlacement()
    }

    override func layout() {
        super.layout()
        updatePlacement()
    }

    func updatePlacement() {
        guard attachedWindow != nil else { return }
        let page = convert(bounds, to: nil)
        let x = pane.convert(NSPoint(x: page.minX, y: page.minY), from: nil).x
        // The native accessory spans the window; its controls follow only the
        // detail column, excluding both sidebars and their reserved widths.
        let frame = NSRect(x: x, y: pane.bounds.minY, width: page.width, height: pane.bounds.height)
        if host.frame != frame { host.frame = frame }
    }

    func detach() {
        if let window = attachedWindow,
           let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        attachedWindow = nil
    }
}

@MainActor
private final class HistoryToolbarAccessoryPane: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
