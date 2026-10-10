import SwiftUI

/// Page-specific safe areas and toolbar behavior remain explicit.
struct PageChromePolicy {
    enum Kind { case standard, artist }
    let kind: Kind
    let queuePresented: Bool
    var scrolled = false
    var hovered = false
    var hasSupplementaryHeader = false

    static func isScrolled(offset: CGFloat) -> Bool { offset > 1 }

    var observesHover: Bool { kind == .artist || queuePresented }
    var usesPageBackdrop: Bool { kind == .standard && (queuePresented || hasSupplementaryHeader) }
    var backdropVisible: Bool { hasSupplementaryHeader || scrolled || hovered }
    var hidesTopScrollEdge: Bool { !backdropVisible }
    var visibleSafeAreaEdges: Edge.Set { kind == .artist ? [.top, .bottom] : [] }
    // Preserve both panel safe areas so the artist header can reflect beneath them.
    var canvasSafeAreaEdges: Edge.Set { [] }

    var toolbarVisibility: Visibility {
        if kind == .artist {
            return scrolled ? .automatic : hovered ? .visible : .hidden
        }
        // A page-local native material replaces the automatic full-width one.
        return usesPageBackdrop ? .hidden : .automatic
    }

    var queueReservation: CGFloat { queuePresented ? Self.queueWidth : 0 }
    var globalSearchOffset: CGFloat { -queueReservation / 2 }
    static let queueWidth: CGFloat = 300
    static let queueToggleWidth: CGFloat = 38
}

/// Both rectangles must be expressed in the same coordinate space. The visible
/// column excludes reserved panels; the canvas may draw underneath them.
struct PageViewport: Equatable {
    let visibleFrame: CGRect
    let canvasFrame: CGRect

    var visibleWidth: CGFloat { max(0, visibleFrame.width) }
    var fullWidth: CGFloat { max(0, canvasFrame.width) }
    var leadingInset: CGFloat { max(0, visibleFrame.minX - canvasFrame.minX) }
    var trailingInset: CGFloat { max(0, canvasFrame.maxX - visibleFrame.maxX) }
    var sideInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: leadingInset, bottom: 0, trailing: trailingInset)
    }
    // Artist artwork uses visibleWidth; its native background effect extends
    // beneath either sidebar without enlarging the original portrait.
    var expandedWidth: CGFloat { visibleWidth + leadingInset + trailingInset }

    static func column(visibleWidth: CGFloat, measuredFullWidth: CGFloat,
                       trailingReservation: CGFloat) -> Self {
        let width = measuredFullWidth > 0 ? measuredFullWidth : visibleWidth + trailingReservation
        return Self(visibleFrame: CGRect(x: 0, y: 0, width: max(0, visibleWidth), height: 0),
                    canvasFrame: CGRect(x: 0, y: 0, width: max(0, width), height: 0))
    }
}

/// Native toolbar measurements and page width are separate from assigned width.
/// Compactness must use the latter, so resizing does not follow stale estimates.
struct PageToolbarLayout {
    let kind: PageChromePolicy.Kind
    let queuePresented: Bool
    let expandedMinimumWidth: CGFloat
    var summaryLeadingPadding: CGFloat = 8

    var panelReservation: CGFloat {
        queuePresented ? PageChromePolicy.queueWidth - PageChromePolicy.queueToggleWidth - 16 : 0
    }
    var minimumWidth: CGFloat { (kind == .artist ? 124 : 80) + panelReservation }

    func preferredWidth(detailWidth: CGFloat, sidebarVisible: Bool,
                        measurement: PageToolbarMeasurement?) -> CGFloat {
        let navigationWidth: CGFloat = sidebarVisible ? 76 : 280
        let measuredWidth = measurement.map { $0.availableWidth + detailWidth - $0.detailWidth }
        let hostWidth = max(80, measuredWidth
            ?? (detailWidth - navigationWidth - PageChromePolicy.queueToggleWidth - 48))
        return max(minimumWidth, hostWidth)
    }

    func controls(assignedWidth: CGFloat, searchExpanded: Bool = false) -> Controls {
        let available = assignedWidth - panelReservation
        let compact = available < expandedMinimumWidth
        let menuWidth: CGFloat = kind == .artist ? 88 : 44
        let searchWidth = min(220, max(36, available - menuWidth))
        let controlsWidth = (compact && !searchExpanded ? 36 : searchWidth) + menuWidth
        return Controls(compact: compact, searchWidth: searchWidth,
            summaryWidth: max(0, available - controlsWidth - 8 - summaryLeadingPadding))
    }

    struct Controls {
        let compact: Bool
        let searchWidth: CGFloat
        let summaryWidth: CGFloat
    }
}

struct PageToolbarBackgroundPreferenceKey: PreferenceKey {
    static let defaultValue: Visibility? = nil
    static func reduce(value: inout Visibility?, nextValue: () -> Visibility?) {
        value = nextValue() ?? value
    }
}

struct PageToolbarMeasurement {
    let availableWidth: CGFloat
    let detailWidth: CGFloat
}
