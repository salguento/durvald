import AppKit
import SwiftUI

/// Uses AppKit's sidebar presentation rather than approximating it with control glass.
struct NativeSidebarPane<Content: View>: NSViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSViewController(context: Context) -> NativeSidebarPaneController {
        NativeSidebarPaneController(content: hostedContent(environment: context.environment))
    }

    func updateNSViewController(_ controller: NativeSidebarPaneController, context: Context) {
        controller.host.rootView = hostedContent(environment: context.environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NativeSidebarPaneController,
                     context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSViewController(_ controller: NativeSidebarPaneController, coordinator: ()) {
        controller.host.rootView = AnyView(EmptyView())
    }

    private func hostedContent(environment: EnvironmentValues) -> AnyView {
        // A hosting controller is a new SwiftUI root. Forward the complete environment,
        // including the store, menu/navigation coordinators and window active state.
        AnyView(content.environment(\.self, environment).ignoresSafeArea())
    }
}

@MainActor
final class NativeSidebarPaneController: NSSplitViewController {
    let host: NSHostingController<AnyView>

    init(content: AnyView) {
        host = NSHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        let sidebar = NSSplitViewItem(sidebarWithViewController: host)
        sidebar.canCollapse = false
        // The outer overlay owns width/visibility. This split supplies only the
        // same native sidebar surface used by the navigation split on the left.
        sidebar.minimumThickness = 0
        sidebar.maximumThickness = NSSplitViewItem.unspecifiedDimension
        sidebar.automaticallyAdjustsSafeAreaInsets = false
        sidebar.allowsFullHeightLayout = false
        addSplitViewItem(sidebar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
