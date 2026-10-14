import Foundation
import XCTest
@testable import Durvald

final class SearchShelfPagingTests: XCTestCase {
    func testRepeatedClicksAdvanceWholePagesAndReverseWithoutDrift() {
        let paging = SearchShelfPaging(itemWidth: 200, itemCount: 20, visibleWidth: 1000)
        var index = 0
        for expected in [4, 8, 12, 16, 16] {
            index = paging.destination(from: index, forward: true)
            XCTAssertEqual(index, expected)
        }
        for expected in [12, 8, 4, 0, 0] {
            index = paging.destination(from: index, forward: false)
            XCTAssertEqual(index, expected)
        }
    }

    func testTrackColumnsAndNarrowWindowsUseWholeBlocks() {
        let tracks = SearchShelfPaging(itemWidth: 464, itemCount: 9, visibleWidth: 1000)
        XCTAssertEqual(tracks.itemsPerPage, 2)
        XCTAssertEqual(tracks.destination(from: 0, forward: true), 2)
        let narrow = SearchShelfPaging(itemWidth: 280, itemCount: 9, visibleWidth: 360)
        XCTAssertEqual(narrow.itemsPerPage, 1)
        XCTAssertEqual(narrow.destination(from: 0, forward: true), 1)
    }

    func testLastPageHasEnoughSpaceToKeepItsLeadingBlockAligned() {
        let paging = SearchShelfPaging(itemWidth: 200, itemCount: 11, visibleWidth: 1000)
        let contentWidth = 11.0 * 200 + 10.0 * SearchShelfPaging.spacing
        let maximumOffset = contentWidth + paging.trailingSlack - (1000 - 48)
        XCTAssertEqual(maximumOffset, Double(paging.lastIndex) * (200 + SearchShelfPaging.spacing))
        XCTAssertEqual(paging.destination(from: 8, forward: true), 7)
        XCTAssertEqual(paging.index(at: maximumOffset), 7)
    }

    func testGesturePositionAndShortResultsStayWithinBounds() {
        let paging = SearchShelfPaging(itemWidth: 200, itemCount: 20, visibleWidth: 1000)
        XCTAssertEqual(paging.index(at: 450), 2)
        XCTAssertEqual(paging.index(at: -50), 0)
        let short = SearchShelfPaging(itemWidth: 200, itemCount: 2, visibleWidth: 1000)
        XCTAssertEqual(short.lastIndex, 0)
        XCTAssertEqual(short.trailingSlack, 0)
        XCTAssertEqual(short.destination(from: 0, forward: true), 0)
    }
    func testButtonsHideInDirectionsWithoutMoreContent() {
        let paging = SearchShelfPaging(itemWidth: 200, itemCount: 11, visibleWidth: 1000)
        let end = CGFloat(paging.lastIndex) * (200 + SearchShelfPaging.spacing)
        XCTAssertFalse(paging.canScroll(forward: false, offset: 0, pendingIndex: nil))
        XCTAssertTrue(paging.canScroll(forward: true, offset: 0, pendingIndex: nil))
        XCTAssertTrue(paging.canScroll(forward: false, offset: end, pendingIndex: nil))
        XCTAssertFalse(paging.canScroll(forward: true, offset: end, pendingIndex: nil))
        XCTAssertTrue(paging.canScroll(forward: false, offset: 300, pendingIndex: nil))
        XCTAssertTrue(paging.canScroll(forward: true, offset: 300, pendingIndex: nil))
        // Hide the exhausted direction immediately, before its animation finishes.
        XCTAssertFalse(paging.canScroll(forward: true, offset: 300, pendingIndex: paging.lastIndex))
        XCTAssertFalse(paging.canScroll(forward: false, offset: 300, pendingIndex: 0))
        let short = SearchShelfPaging(itemWidth: 200, itemCount: 2, visibleWidth: 1000)
        for forward in [true, false] {
            XCTAssertFalse(short.canScroll(forward: forward, offset: 0, pendingIndex: nil))
        }
    }

}
