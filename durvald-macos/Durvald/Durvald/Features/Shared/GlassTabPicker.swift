import SwiftUI

struct GlassTabOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var icon: String? = nil
    var accessibilityIdentifier: String? = nil

    var id: Value { value }
}

/// Shared chrome with independent policies for sidebar width and foreground.
struct GlassTabPicker<Value: Hashable>: View {
    enum Distribution {
        case equal
        case selectedExpands
    }

    enum Foreground {
        case allPrimary
        case selectedPrimary
    }

    static var height: CGFloat { 30 }
    private var inset: CGFloat { 3 }
    private var spacing: CGFloat { 3 }
    private var compactWidth: CGFloat { 28 }

    let options: [GlassTabOption<Value>]
    @Binding var selection: Value
    var distribution: Distribution = .equal
    var foreground: Foreground = .allPrimary
    var selectionAnimation: Animation? = nil
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Group {
            switch distribution {
            case .equal:
                tabs(selectedWidth: nil)
                    .padding(inset)
                    .frame(maxWidth: .infinity)
            case .selectedExpands:
                // Do not contribute the labels' ideal width to split-view sizing.
                GeometryReader { geometry in
                    let otherTabsWidth = CGFloat(max(0, options.count - 1)) * (compactWidth + spacing)
                    let selectedWidth = max(0, geometry.size.width - 2 * inset - otherTabsWidth)
                    tabs(selectedWidth: selectedWidth)
                        .padding(inset)
                }
            }
        }
        .frame(height: Self.height)
        .glassEffect(.regular, in: .capsule)
        .animation(.easeOut(duration: 0.15), value: appearsActive)
        .accessibilityElement(children: .contain)
    }

    private func tabs(selectedWidth: CGFloat?) -> some View {
        HStack(spacing: spacing) {
            ForEach(options) { option in
                Button {
                    if let selectionAnimation {
                        withAnimation(selectionAnimation) { selection = option.value }
                    } else {
                        selection = option.value
                    }
                } label: {
                    tabLabel(option, adaptive: selectedWidth != nil)
                        .foregroundStyle(tabForeground(selected: selection == option.value))
                        .frame(maxWidth: selectedWidth == nil ? .infinity : nil)
                        .frame(height: Self.height - 2 * inset)
                        .frame(width: selectedWidth.map { selection == option.value ? $0 : compactWidth })
                        .contentShape(Rectangle())
                        .background {
                            if selection == option.value {
                                Capsule()
                                    .fill(Color(nsColor: .labelColor).opacity(appearsActive ? 0.12 : 0.07))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(option.title)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                .modifier(TabIdentifier(identifier: option.accessibilityIdentifier))
            }
        }
    }

    @ViewBuilder
    private func tabLabel(_ option: GlassTabOption<Value>, adaptive: Bool) -> some View {
        if adaptive, let icon = option.icon {
            ViewThatFits(in: .horizontal) {
                if option.value == selection {
                    // Every selection fits against the widest complete label.
                    ZStack {
                        ForEach(options) { candidate in
                            completeLabel(candidate)
                                .opacity(candidate.value == option.value ? 1 : 0)
                                .accessibilityHidden(candidate.value != option.value)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                Image(systemName: icon)
            }
        } else {
            completeLabel(option)
        }
    }

    private func completeLabel(_ option: GlassTabOption<Value>) -> some View {
        HStack(spacing: 5) {
            if let icon = option.icon { Image(systemName: icon) }
            Text(option.title).lineLimit(1)
        }
    }

    private func tabForeground(selected: Bool) -> Color {
        if foreground == .selectedPrimary, !selected { return .secondary }
        return Color(nsColor: appearsActive ? .labelColor : .secondaryLabelColor)
    }
}

private struct TabIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) }
        else { content }
    }
}
