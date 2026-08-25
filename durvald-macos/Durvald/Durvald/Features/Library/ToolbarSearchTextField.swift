import AppKit
import SwiftUI

struct ToolbarSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let isPresented: Bool
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.placeholderString = "Músicas, álbuns, artistas e playlists"
        textField.setAccessibilityIdentifier("search.field")
        context.coordinator.installFocusDismissalMonitor(for: textField)
        return textField
    }

    static func dismantleNSView(
        _ textField: NSTextField,
        coordinator: Coordinator
    ) {
        coordinator.removeFocusDismissalMonitor()
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.parent = self

        if textField.stringValue != text {
            textField.stringValue = text
        }

        if !isPresented {
            if textField.currentEditor() != nil {
                textField.window?.makeFirstResponder(nil)
            }
            return
        }

        guard context.coordinator.lastFocusRequest != focusRequest else {
            return
        }

        context.coordinator.lastFocusRequest = focusRequest
        let coordinator = context.coordinator
        Task { @MainActor [weak textField, weak coordinator] in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            guard let textField, let coordinator,
                  let window = textField.window else { return }

            if window.makeFirstResponder(textField) {
                coordinator.parent.isFocused = true
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate, @unchecked Sendable {
        var parent: ToolbarSearchTextField
        var lastFocusRequest = -1

        private weak var monitoredTextField: NSTextField?
        private var focusDismissalMonitor: Any?

        init(parent: ToolbarSearchTextField) {
            self.parent = parent
        }

        deinit {
            if let focusDismissalMonitor {
                NSEvent.removeMonitor(focusDismissalMonitor)
            }
        }

        func installFocusDismissalMonitor(for textField: NSTextField) {
            monitoredTextField = textField
            focusDismissalMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.dismissSearchFocusIfNeeded(for: event)
                }
                return event
            }
        }

        func removeFocusDismissalMonitor() {
            guard let focusDismissalMonitor else { return }
            NSEvent.removeMonitor(focusDismissalMonitor)
            self.focusDismissalMonitor = nil
        }

        private func dismissSearchFocusIfNeeded(for event: NSEvent) {
            guard let window = event.window,
                  window === monitoredTextField?.window,
                  let editor = window.firstResponder as? NSTextView,
                  editor.isFieldEditor,
                  let rootView = window.contentView?.superview,
                  let activeField = textField(using: editor, in: rootView),
                  isSearchField(activeField) else { return }

            let hitView = rootView.hitTest(event.locationInWindow)
            guard !isInsideActiveField(
                    hitView,
                    field: activeField,
                    editor: editor
                  ),
                  !isInsideSearchContainer(hitView) else { return }

            window.makeFirstResponder(nil)
        }

        private func textField(
            using editor: NSTextView,
            in view: NSView
        ) -> NSTextField? {
            if let textField = view as? NSTextField,
               textField.currentEditor() === editor {
                return textField
            }

            for subview in view.subviews {
                if let textField = textField(using: editor, in: subview) {
                    return textField
                }
            }

            return nil
        }

        private func isSearchField(_ textField: NSTextField) -> Bool {
            if textField === monitoredTextField {
                return true
            }

            return textField.placeholderString?.hasPrefix("Pesquisar em ") == true
        }

        private func isInsideActiveField(
            _ hitView: NSView?,
            field: NSTextField,
            editor: NSTextView
        ) -> Bool {
            var currentView = hitView

            while let view = currentView {
                if view === field || view === editor {
                    return true
                }
                currentView = view.superview
            }

            return false
        }

        private func isInsideSearchContainer(_ hitView: NSView?) -> Bool {
            let identifiers: Set<String> = [
                "search.container",
                "search.clear",
                "sidebar.sectionSearch.container",
                "sidebar.sectionSearch.clear"
            ]
            var currentView = hitView

            while let view = currentView {
                if identifiers.contains(view.accessibilityIdentifier()) {
                    return true
                }
                currentView = view.superview
            }

            return false
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return false
            }

            parent.text = ""
            control.stringValue = ""
            parent.isFocused = true
            return true
        }
    }
}
