import AppKit
import SwiftUI

enum WindowSplitLayoutPolicy {
    static let sidebarMinimumWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 240
    static let sidebarMaximumWidth: CGFloat = 280
}

@MainActor
final class WindowSplitLayoutCoordinator {
    fileprivate let sidebarController = SidebarLayoutController()
    fileprivate let inspectorController = InspectorLayoutController()

    func prepareInspectorPresentation() {
        inspectorController.configure()
    }
}

@MainActor
private final class SidebarLayoutController {
    weak var anchor: NSView?
    private weak var sidebarItem: NSSplitViewItem?

    func attach(to anchor: NSView) {
        guard self.anchor !== anchor else { return }
        self.anchor = anchor
        invalidateResolvedHierarchy()
    }

    func invalidateResolvedHierarchy() {
        sidebarItem = nil
    }

    func configure() {
        guard let anchor else { return }

        if let sidebarItem {
            applyConfiguration(to: sidebarItem)
            return
        }

        var ancestor = anchor.superview

        while let view = ancestor {
            if let splitView = view as? NSSplitView,
               let controller = splitView.delegate as? NSSplitViewController,
               let sidebar = controller.splitViewItems.first(where: {
                   anchor.isDescendant(of: $0.viewController.view)
               }),
               sidebar.behavior != .inspector {
                sidebarItem = sidebar
                applyConfiguration(to: sidebar)
                return
            }
            ancestor = view.superview
        }
    }

    private func applyConfiguration(to sidebar: NSSplitViewItem) {
        if sidebar.minimumThickness != WindowSplitLayoutPolicy.sidebarMinimumWidth {
            sidebar.minimumThickness = WindowSplitLayoutPolicy.sidebarMinimumWidth
        }
    }
}

struct SidebarSplitLayout: NSViewRepresentable {
    let coordinator: WindowSplitLayoutCoordinator

    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView(controller: coordinator.sidebarController)
    }

    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.scheduleConfiguration()
    }

    final class ConfigurationView: NSView {
        private let controller: SidebarLayoutController
        private var configurationScheduled = false

        fileprivate init(controller: SidebarLayoutController) {
            self.controller = controller
            super.init(frame: .zero)
            controller.attach(to: self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            controller.invalidateResolvedHierarchy()
            scheduleConfiguration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            controller.invalidateResolvedHierarchy()
            scheduleConfiguration()
        }

        override func layout() {
            super.layout()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            guard !configurationScheduled else { return }
            configurationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configurationScheduled = false
                self.controller.attach(to: self)
                self.controller.configure()
            }
        }
    }
}

/// Configure the outer split from its always-present content, even while the
/// inspector is collapsed. Keep the nested navigation sidebar's glass unchanged.
@MainActor
private final class InspectorLayoutController {
    weak var anchor: NSView?
    private weak var inspectorItem: NSSplitViewItem?
    private weak var contentItem: NSSplitViewItem?

    func attach(to anchor: NSView) {
        guard self.anchor !== anchor else { return }
        self.anchor = anchor
        invalidateResolvedHierarchy()
    }

    func invalidateResolvedHierarchy() {
        inspectorItem = nil
        contentItem = nil
    }

    func configure() {
        guard let anchor else { return }
        anchor.window?.titlebarSeparatorStyle = .none

        if let inspectorItem, let contentItem {
            applyConfiguration(inspector: inspectorItem, content: contentItem)
            return
        }

        var ancestor = anchor.superview

        while let view = ancestor {
            if let splitView = view as? NSSplitView,
               let controller = splitView.delegate as? NSSplitViewController,
               let inspector = controller.splitViewItems.first(where: { $0.behavior == .inspector }),
               let content = controller.splitViewItems.first(where: {
                   $0 !== inspector && anchor.isDescendant(of: $0.viewController.view)
               }) {
                inspectorItem = inspector
                contentItem = content
                applyConfiguration(inspector: inspector, content: content)
                return
            }
            ancestor = view.superview
        }
    }

    private func applyConfiguration(inspector: NSSplitViewItem, content: NSSplitViewItem) {
        // Avoid counting the queue's safe area twice through nested splits.
        if content.automaticallyAdjustsSafeAreaInsets {
            content.automaticallyAdjustsSafeAreaInsets = false
        }
        if inspector.collapseBehavior != .preferResizingSiblingsWithFixedSplitView {
            inspector.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        }
    }
}

struct InspectorSplitLayout: NSViewRepresentable {
    let coordinator: WindowSplitLayoutCoordinator

    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView(controller: coordinator.inspectorController)
    }

    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.scheduleConfiguration()
    }

    final class ConfigurationView: NSView {
        private let controller: InspectorLayoutController
        private var configurationScheduled = false

        fileprivate init(controller: InspectorLayoutController) {
            self.controller = controller
            super.init(frame: .zero)
            controller.attach(to: self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            controller.invalidateResolvedHierarchy()
            scheduleConfiguration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            controller.invalidateResolvedHierarchy()
            scheduleConfiguration()
        }

        override func layout() {
            super.layout()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            guard !configurationScheduled else { return }
            configurationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configurationScheduled = false
                self.controller.attach(to: self)
                self.controller.configure()
            }
        }
    }
}
