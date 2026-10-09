import AppKit
import SwiftUI

/// One bridge for all subjects; capture policy remains specific to the presentation.
struct NativeLibraryMenu: NSViewRepresentable {
    let mode: LibraryMenuCaptureMode
    let configure: @MainActor (TrackMenuController) -> Void

    func makeCoordinator() -> TrackMenuController { TrackMenuController() }

    func makeNSView(context: Context) -> LibraryMenuCaptureView {
        LibraryMenuCaptureView(mode: mode)
    }

    func updateNSView(_ view: LibraryMenuCaptureView, context: Context) {
        configure(context.coordinator)
        view.mode = mode
        view.menu = context.coordinator.rootMenu
    }

    static func dismantleNSView(_ view: LibraryMenuCaptureView, coordinator: TrackMenuController) {
        view.menu = nil
        coordinator.detach()
    }
}

enum LibraryMenuCaptureMode {
    case context, options

    func captures(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .options: return true
        case .context:
            return type == .rightMouseDown || (type == .leftMouseDown && modifiers.contains(.control))
        }
    }
}

final class LibraryMenuCaptureView: NSView {
    var mode: LibraryMenuCaptureMode

    init(mode: LibraryMenuCaptureMode) {
        self.mode = mode
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if mode == .options { return super.hitTest(point) }
        guard let event = NSApp.currentEvent,
              mode.captures(type: event.type, modifiers: event.modifierFlags) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .options, let menu else { super.mouseDown(with: event); return }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.minY - 4), in: self)
    }
}

/// Materializes definitions without executing domain operations.
@MainActor
enum NativeLibraryMenuPresenter {
    static func populate(_ menu: NSMenu, items: [LibraryMenuItem], target: AnyObject,
                         selector: (LibraryMenuCommand) -> Selector,
                         playlistPicker: NSMenu, containingPlaylists: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        for definition in items {
            let item: NSMenuItem
            switch definition {
            case .separator:
                item = .separator()
            case .action(let action):
                item = NSMenuItem(title: action.title, action: selector(action.command), keyEquivalent: "")
                item.target = target
                item.tag = action.tag
                item.state = action.isSelected ? .on : .off
                item.isEnabled = action.isEnabled
                item.representedObject = action.track
                if let image = action.systemImage {
                    item.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
                }
            case .submenu(let title, let children):
                item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let child = NSMenu(title: title)
                populate(child, items: children, target: target, selector: selector,
                         playlistPicker: playlistPicker, containingPlaylists: containingPlaylists)
                item.submenu = child
            case .playlistPicker:
                item = NSMenuItem(title: "Adicionar à playlist", action: nil, keyEquivalent: "")
                item.submenu = playlistPicker
            case .containingPlaylists:
                item = NSMenuItem(title: "Ir à playlist", action: nil, keyEquivalent: "")
                item.submenu = containingPlaylists
            }
            menu.addItem(item)
        }
    }
}
