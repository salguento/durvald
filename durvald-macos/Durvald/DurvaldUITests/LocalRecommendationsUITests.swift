import XCTest

final class LocalRecommendationsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testReasonsDismissalPersistenceRestoreAndAlbumNavigation() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture", "--recommendations-fixture", "-albums.minimumRating.halfSteps", "0"]
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = UUID().uuidString
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["sidebar.home"].waitForExistence(timeout: 15))
        app.menuBars.menuBarItems["Window"].click(); app.menuItems["Fill"].click()
        let home = app.descendants(matching: .any)["home.page"].firstMatch
        let shelf = app.descendants(matching: .any)["home.recommendations"].firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 10))
        home.scroll(byDeltaX: 0, deltaY: -1200)
        let card = app.descendants(matching: .any)["home.recommendation.4"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        XCTAssertTrue(shelf.staticTexts["Gênero em comum: Jazz"].exists)
        XCTAssertTrue(app.staticTexts["Recomendações para você"].exists)
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Recomendações locais com motivos"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["home.recommendation.dismiss.4"].click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: card)
        waitForExpectations(timeout: 8)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["sidebar.home"].waitForExistence(timeout: 15))
        XCTAssertTrue(shelf.waitForExistence(timeout: 10))
        home.scroll(byDeltaX: 0, deltaY: -1200)
        let options = app.menuButtons["home.recommendations.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 8))
        XCTAssertFalse(card.exists)
        options.click(); app.menuItems["Restaurar sugestões dispensadas"].click()
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.buttons["album.4"].firstMatch.click()
        XCTAssertTrue(app.buttons["album.header.artwork"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["navigation.back"].click()
        XCTAssertTrue(shelf.waitForExistence(timeout: 8))
    }
}
