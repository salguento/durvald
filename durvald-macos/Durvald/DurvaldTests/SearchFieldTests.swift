import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Durvald

@MainActor
final class SearchFieldTests: XCTestCase {
    func testFocusRequestWaitsForWindowAndDoesNotReselectOnRepeat() throws {
        let state = SearchTestState()
        state.text = "abcdef"
        state.request = 0
        let parent = native(state)
        let coordinator = parent.makeCoordinator()
        let field = NSTextField(string: state.text)
        coordinator.focusPendingSearch(in: field)
        XCTAssertEqual(coordinator.lastFocusRequest, -1)
        let window = window(content: field)
        defer { window.contentView = nil }
        coordinator.focusPendingSearch(in: field)
        XCTAssertEqual(coordinator.lastFocusRequest, state.request)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 0))
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.focusPendingSearch(in: field)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testEscapeDropsNativeFocusWithoutDeletingQuery() {
        let state = SearchTestState()
        state.text = "query"
        state.focused = true
        let coordinator = native(state).makeCoordinator()
        let field = NSTextField(string: state.text)
        let window = window(content: field)
        defer { window.contentView = nil }
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(coordinator.control(field, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(state.focused)
        XCTAssertEqual(state.text, "query")
        XCTAssertFalse(coordinator.control(field, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }

    func testNativeEditingUpdatesBindingAndFocus() {
        let state = SearchTestState()
        let coordinator = native(state).makeCoordinator()
        let field = NSTextField(string: "typed")
        let notification = Notification(name: NSText.didChangeNotification, object: field)
        coordinator.controlTextDidBeginEditing(notification)
        coordinator.controlTextDidChange(notification)
        XCTAssertTrue(state.focused)
        XCTAssertEqual(state.text, "typed")
        coordinator.controlTextDidEndEditing(notification)
        XCTAssertFalse(state.focused)
    }

    func testSharedClearUpdatesActiveEditorAndRestoresFocus() async throws {
        let state = SearchTestState()
        state.text = "query"
        let search = toolbar(state)
        let host = NSHostingView(rootView: search)
        let window = window(content: host)
        defer { window.contentView = nil }
        await layout(host)
        let field = try XCTUnwrap(fields(in: host).first { $0.accessibilityIdentifier() == "search.field" })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        search.performClear()
        await layout(host)
        XCTAssertEqual(state.text, "")
        XCTAssertEqual(field.stringValue, "")
        XCTAssertTrue(state.focused)
        XCTAssertTrue(window.firstResponder === field.currentEditor())
    }

    func testActiveEditorKeepsCursorUntilAnExplicitFocusRequest() async throws {
        let state = SearchTestState()
        state.text = "abcdef"
        state.request = 0
        let host = NSHostingView(rootView: toolbar(state))
        let window = window(content: host)
        defer { window.contentView = nil }
        await layout(host)
        let field = try XCTUnwrap(fields(in: host).first { $0.accessibilityIdentifier() == "search.field" })
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        // A stale binding update must not replace the active field editor.
        state.text = "abcde"
        await layout(host)
        XCTAssertEqual(field.stringValue, "abcdef")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0))
        state.request += 1
        await layout(host)
        XCTAssertEqual(field.stringValue, "abcde")
    }

    func testCompactFieldRemovesNativeEditorAndExpandedUsesSharedField() async {
        for expanded in [false, true] {
            let host = NSHostingView(rootView: LibraryToolbarSearchField(
                searchText: .constant("query"), placeholder: "Pesquisar faixas",
                identifier: "artist.tracks.search", prefersCompact: true,
                expandedWidth: 220, isExpanded: .constant(expanded)))
            let window = window(content: host)
            await layout(host)
            let searchFields = fields(in: host).filter {
                $0.accessibilityIdentifier() == "artist.tracks.search.field"
            }
            XCTAssertEqual(searchFields.count, expanded ? 1 : 0)
            window.contentView = nil
        }
    }

    func testToolbarKeepsAccessibleLabelAndSinglePlaceholderSource() async throws {
        let state = SearchTestState()
        let host = NSHostingView(rootView: toolbar(state))
        let window = window(content: host)
        defer { window.contentView = nil }
        await layout(host)
        let field = try XCTUnwrap(fields(in: host).first { $0.accessibilityIdentifier() == "search.field" })
        XCTAssertEqual(field.accessibilityLabel(), "Pesquisar na biblioteca")
        XCTAssertEqual(field.placeholderString ?? "", "", "The shared overlay owns the visible placeholder")
        XCTAssertEqual(host.frame.height, 36, accuracy: 1)
    }

    private func native(_ state: SearchTestState) -> ToolbarSearchTextField {
        ToolbarSearchTextField(text: Binding(get: { state.text }, set: { state.text = $0 }),
            isFocused: Binding(get: { state.focused }, set: { state.focused = $0 }),
            isPresented: true, focusRequest: state.request)
    }

    private func toolbar(_ state: SearchTestState) -> ToolbarSearchField {
        ToolbarSearchField(text: Binding(get: { state.text }, set: { state.text = $0 }),
            isFocused: Binding(get: { state.focused }, set: { state.focused = $0 }),
            focusRequest: Binding(get: { state.request }, set: { state.request = $0 }),
            placeholder: "Biblioteca", identifier: "search",
            accessibilityLabel: "Pesquisar na biblioteca", accessory: .reservedClear)
    }

    private func window(content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 36),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        return window
    }

    private func layout(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
    }

    private func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }
}

@MainActor @Observable
private final class SearchTestState {
    var text = ""
    var focused = false
    var request = -1
}
