import AppKit
import SwiftUI

/// Keeps the inspector beside the navigation split instead of overlaying it.
/// Nested split views otherwise count the inspector's trailing safe area twice
/// when deriving the window's minimum width on macOS 26.
struct InspectorSplitLayout: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView()
    }

    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.scheduleConfiguration()
    }

    final class ConfigurationView: NSView {
        private var configurationScheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleConfiguration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        override func layout() {
            super.layout()
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            guard !configurationScheduled else { return }
            configurationScheduled = true

            // SwiftUI may still be attaching the inspector's controller. Apply
            // the configuration after the current hierarchy/layout update.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.configurationScheduled = false
                self.configureEnclosingInspector()
            }
        }

        private func configureEnclosingInspector() {
            guard window != nil else { return }
            var ancestor = superview

            while let view = ancestor {
                if let splitView = view as? NSSplitView,
                   let controller = splitView.delegate as? NSSplitViewController,
                   let inspector = controller.splitViewItems.first(where: {
                       $0.behavior == .inspector
                           && isDescendant(of: $0.viewController.view)
                   }) {
                    for item in controller.splitViewItems where item !== inspector {
                        // Only the outer content stops extending behind the queue.
                        // The nested navigation sidebar keeps its native glass,
                        // safe-area behavior and full-height layout unchanged.
                        if item.automaticallyAdjustsSafeAreaInsets {
                            item.automaticallyAdjustsSafeAreaInsets = false
                        }
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
