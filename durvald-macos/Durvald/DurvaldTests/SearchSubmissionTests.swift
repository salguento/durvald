import XCTest
@testable import Durvald

final class SearchSubmissionTests: XCTestCase {
    func testShortcutOpensHomeAndRequestsFocusWithoutExecutingSearch() {
        var state = ContentShellState()
        state.navigationHistory.navigate(to: .albums)
        state.requestSearchFocus()
        XCTAssertEqual(state.navigationHistory.currentRoute, .section(.home))
        XCTAssertEqual(state.searchFocusRequest, 0)
        XCTAssertEqual(state.searchSubmissionRevision, 0)
        state.requestSearchFocus()
        XCTAssertEqual(state.searchFocusRequest, 1)
    }

    func testLeavingSearchDiscardsTheConsumedFocusRequestBeforeReturningHome() {
        var state = ContentShellState()
        XCTAssertEqual(state.searchFocusRequest, -1)
        state.requestSearchFocus()
        state.navigationHistory.navigate(to: .albums)
        state.handleDestinationChange(.albums)
        XCTAssertEqual(state.searchFocusRequest, -1)
        state.navigationHistory.navigate(to: .home)
        state.handleDestinationChange(.home)
        XCTAssertEqual(state.searchFocusRequest, -1)
        XCTAssertFalse(state.isSearchFocused)
        state.requestSearchFocus()
        XCTAssertEqual(state.searchFocusRequest, 0)
    }

    func testOnlyNonemptySubmissionOpensDedicatedResults() {
        var state = ContentShellState()
        state.searchText = "  "
        state.submitSearch()
        XCTAssertEqual(state.navigationHistory.currentRoute, .section(.home))
        XCTAssertEqual(state.searchSubmissionRevision, 0)
        state.searchText = "  Marina  "
        state.submitSearch()
        XCTAssertEqual(state.navigationHistory.currentRoute, .section(.search))
        XCTAssertEqual(state.submittedSearchText, "Marina")
    }

    func testTypingDoesNotChangeTheExecutedQuery() {
        var state = ContentShellState()
        state.searchText = "marina"
        XCTAssertEqual(state.submittedSearchText, "")
        XCTAssertEqual(state.searchSubmissionRevision, 0)
        state.submitSearch()
        state.searchText = "outra pesquisa"
        XCTAssertEqual(state.submittedSearchText, "marina")
        XCTAssertEqual(state.searchSubmissionRevision, 1)
    }

    func testEnterNormalizesAndCanRepeatTheSameQuery() {
        var state = ContentShellState()
        state.searchText = "  marina  "
        state.submitSearch()
        XCTAssertEqual(state.submittedSearchText, "marina")
        state.submitSearch()
        XCTAssertEqual(state.submittedSearchText, "marina")
        XCTAssertEqual(state.searchSubmissionRevision, 2)
    }
}
