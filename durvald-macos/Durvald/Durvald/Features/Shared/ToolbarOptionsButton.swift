import SwiftUI

enum ToolbarControlMetrics {
    static let size: CGFloat = 36
    static let spacing: CGFloat = 8
}

/// Menu presentation only; each consumer owns its commands and preferences.
struct ToolbarOptionsButton<MenuContent: View>: View {
    enum Outline: Shape {
        case circle, capsule

        func path(in rect: CGRect) -> Path {
            switch self {
            case .circle: Circle().path(in: rect)
            case .capsule: Capsule().path(in: rect)
            }
        }
    }

    enum Appearance {
        case glass, automatic
    }

    let title: String
    var systemImage = "line.3.horizontal.decrease"
    var controlSize = ToolbarControlMetrics.size
    var controlWidth: CGFloat? = nil
    var outline: Outline = .circle
    var appearance: Appearance = .glass
    @ViewBuilder let content: () -> MenuContent

    var body: some View {
        Menu(content: content) {
            ZStack {
                Color.clear
                Image(systemName: systemImage)
            }
            .frame(width: controlWidth ?? controlSize, height: controlSize)
            .contentShape(outline)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: controlWidth ?? controlSize, height: controlSize)
        .contentShape(outline)
        .clipShape(outline)
        .modifier(Presentation(appearance: appearance, outline: outline))
        .help(title)
        .accessibilityLabel(title)
    }

    private struct Presentation: ViewModifier {
        let appearance: Appearance
        let outline: Outline

        @ViewBuilder
        func body(content: Content) -> some View {
            switch appearance {
            case .glass:
                switch outline {
                case .circle:
                    content.buttonStyle(.plain).glassEffect(.regular, in: .circle)
                case .capsule:
                    content.buttonStyle(.plain).glassEffect(.regular, in: .capsule)
                }
            case .automatic:
                content.buttonStyle(.automatic)
            }
        }
    }
}
