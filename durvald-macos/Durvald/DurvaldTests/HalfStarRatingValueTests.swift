import XCTest
@testable import Durvald

final class HalfStarRatingValueTests: XCTestCase {
    func testExactFractionalSymbolsAndDistinctZero() {
        XCTAssertEqual(RatingValues.symbol(star: 1, rating: 7), "star.fill")
        XCTAssertEqual(RatingValues.symbol(star: 4, rating: 7), "star.leadinghalf.filled")
        XCTAssertEqual(RatingValues.symbol(star: 5, rating: 7), "star")
        XCTAssertEqual(PersonalValueLabels.rating(nil), "Sem avaliação")
        XCTAssertEqual(PersonalValueLabels.rating(0), "0 de 5")
        XCTAssertEqual(RatingValues.ruleValue(7), "3.5")
        XCTAssertEqual(RatingValues.ruleValue(8), "4")
    }

    func testWholeScaleRetainsExistingFractionalFilter() {
        XCTAssertEqual(RatingValues.options(.wholeStars), [0, 2, 4, 6, 8, 10])
        XCTAssertEqual(RatingValues.options(.wholeStars, including: 7), [0, 2, 4, 6, 7, 8, 10])
        XCTAssertEqual(RatingValues.options(.halfStars), Array(0...10))
    }

    func testWholeStarFilterMigratesOnlyOnce() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(4, forKey: "albums.minimumRating")
        RatingPreferences.migrateFilterPreferences(defaults)
        XCTAssertEqual(defaults.integer(forKey: "albums.minimumRating.halfSteps"), 8)
        defaults.set(7, forKey: "albums.minimumRating.halfSteps")
        RatingPreferences.migrateFilterPreferences(defaults)
        XCTAssertEqual(defaults.integer(forKey: "albums.minimumRating.halfSteps"), 7)
    }
}
