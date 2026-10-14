import XCTest
@testable import Durvald

final class SearchSubmissionTests: XCTestCase {
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
