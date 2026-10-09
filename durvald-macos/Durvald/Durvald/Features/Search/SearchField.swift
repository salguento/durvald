import AppKit
import SwiftUI

/// Presentation shared by native toolbar and SwiftUI inline editors.
enum SearchFieldStyle {
    case toolbar, inline, sidebar, picker

    var height: CGFloat { self == .sidebar ? 32 : 36 }
    var horizontalPadding: CGFloat { self == .sidebar ? 8 : 12 }
}

enum SearchFieldAccessory {
    case none, clear, reservedClear, close
}

private struct SearchFieldChrome<Editor: View>: View {
    @Binding var text: String
    let style: SearchFieldStyle
    let accessory: SearchFieldAccessory
    let identifier: String
    let action: () -> Void
    @ViewBuilder let editor: () -> Editor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(style == .sidebar ? .system(size: 16) : nil)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
                .frame(width: style == .sidebar ? 20 : style == .picker ? 14 : nil)
            editor()
            if accessory != .none, accessory != .clear || !text.isEmpty {
                Button(action: action) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(accessory == .reservedClear && text.isEmpty ? 0 : 1)
                .allowsHitTesting(accessory != .reservedClear || !text.isEmpty)
                .accessibilityHidden(accessory == .reservedClear && text.isEmpty)
                .accessibilityLabel(accessory == .close ? "Fechar pesquisa" : "Limpar pesquisa")
                .accessibilityIdentifier("\(identifier).clear")
                .help(accessory == .close ? "Fechar pesquisa" : "Limpar pesquisa")
            }
        }
        .padding(.horizontal, style.horizontalPadding)
        .frame(height: style.height)
        .accessibilityElement(children: .contain)
        .modifier(SearchFieldBackground(style: style))
    }
}

private struct SearchFieldBackground: ViewModifier {
    let style: SearchFieldStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .toolbar: content.glassEffect(.regular.interactive(), in: .capsule)
        case .sidebar: content.glassEffect(.regular, in: .capsule)
        case .inline: content.background(Color.primary.opacity(0.08), in: .capsule)
        case .picker: content.background(.quaternary, in: .capsule)
        }
    }
}

/// Keeps the AppKit field editor and explicit focus requests used by toolbars.
struct ToolbarSearchField: View {
    @Environment(\.appearsActive) private var appearsActive
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var focusRequest: Int
    let placeholder: String
    let identifier: String
    var accessibilityLabel: String? = nil
    var accessory: SearchFieldAccessory = .clear
    var focusColor = Color(nsColor: .keyboardFocusIndicatorColor)
    var onActivate: (() -> Void)? = nil

    var body: some View {
        SearchFieldChrome(text: $text, style: .toolbar, accessory: accessory,
                          identifier: identifier, action: performClear) {
            ToolbarSearchTextField(
                text: $text, isFocused: $isFocused, isPresented: true,
                focusRequest: focusRequest, placeholder: "",
                accessibilityLabel: accessibilityLabel ?? placeholder,
                accessibilityIdentifier: "\(identifier).field"
            )
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: NSFont.systemFontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityIdentifier("\(identifier).container")
        .overlay {
            Capsule()
                .strokeBorder(focusColor, lineWidth: 2)
                .opacity(isFocused && appearsActive ? 1 : 0)
                .allowsHitTesting(false)
        }
        .contentShape(Capsule())
        .simultaneousGesture(TapGesture().onEnded { onActivate?() })
    }

    func performClear() {
        text = ""
        focusRequest &+= 1
    }
}

/// Inline callers own Escape/submit policy and retain their FocusState.
struct InlineSearchField: View {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    var placeholder = "Pesquisar"
    let identifier: String
    var fieldIdentifier: String? = nil
    var containerIdentifier: String? = nil
    var style: SearchFieldStyle = .inline
    var accessory: SearchFieldAccessory = .none
    var onAction: (() -> Void)? = nil
    var onSubmit: () -> Void = {}
    let onExit: () -> Void

    var body: some View {
        SearchFieldChrome(text: $text, style: style, accessory: accessory,
                          identifier: identifier, action: performAction) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onExit)
                .accessibilityIdentifier(fieldIdentifier ?? "\(identifier).field")
        }
        .accessibilityIdentifier(containerIdentifier ?? "\(identifier).container")
    }

    private func performAction() {
        if let onAction {
            onAction()
        } else {
            text = ""
            Task { @MainActor in
                await Task.yield()
                focus.wrappedValue = true
            }
        }
    }

}
