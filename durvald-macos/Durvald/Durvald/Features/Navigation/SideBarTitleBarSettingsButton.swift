import SwiftUI
import AppKit

@MainActor
struct SideBarTitleBarSettingsButton: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> SidebarSettingsInstallerView {
        SidebarSettingsInstallerView(action: action)
    }

    func updateNSView(
        _ nsView: SidebarSettingsInstallerView,
        context: Context
    ) {
        nsView.action = action
    }

    static func dismantleNSView(
        _ nsView: SidebarSettingsInstallerView,
        coordinator: Void
    ) {
        nsView.uninstall()
    }
}

@MainActor
final class SidebarSettingsInstallerView: NSView {
    var action: () -> Void
    private weak var settingsButton: NSButton?

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) não é suportado")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        install()
    }

    func uninstall() {
        settingsButton?.removeFromSuperview()
        settingsButton = nil
    }

    private func install() {
        uninstall()

        guard
            let window,
            let zoomButton = window.standardWindowButton(.zoomButton),
            let titlebarContainer = zoomButton.superview
        else {
            return
        }

        let image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Configuração"
        ) ?? NSImage()

        let button = SidebarHoverSettingsButton(
            image: image,
            target: self,
            action: #selector(openSettings)
        )

        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = "Abrir Configuração"
        button.setAccessibilityIdentifier("sidebar.settings")
        button.setAccessibilityLabel("Configuração")
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.translatesAutoresizingMaskIntoConstraints = false

        titlebarContainer.addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(
                equalTo: zoomButton.trailingAnchor,
                constant: 16
            ),
            button.centerYAnchor.constraint(
                equalTo: zoomButton.centerYAnchor
            ),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 18),
        ])

        settingsButton = button
    }

    @objc
    private func openSettings() {
        action()
    }
}

@MainActor
final class SidebarHoverSettingsButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeInKeyWindow,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )

        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateHoverAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateHoverAppearance()
    }

    private func updateHoverAppearance() {
        layer?.backgroundColor = isHovering
            ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }
}
