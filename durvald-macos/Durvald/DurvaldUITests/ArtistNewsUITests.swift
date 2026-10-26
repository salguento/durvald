import XCTest

final class ArtistNewsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testSidebarOfflineFeedSaveSeenAndSearch() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture", "--artist-news-fixture"]
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = UUID().uuidString
        app.launch(); defer { app.terminate() }
        let news = app.buttons["sidebar.news"]
        XCTAssertTrue(news.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(news.frame.minY, app.buttons["sidebar.home"].frame.minY)
        XCTAssertLessThan(news.frame.minY, app.buttons["sidebar.listenList"].frame.minY)
        news.click()
        let recent = app.descendants(matching: .any)["news.item.11111111-1111-4111-8111-111111111111"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["news.open.11111111-1111-4111-8111-111111111111"].label.contains("Novidade recente"))
        XCTAssertTrue(app.buttons["news.open.22222222-2222-4222-8222-222222222222"].label.contains("Próximo lançamento"))
        recent.buttons["listenList.save"].click()
        app.buttons["sidebar.listenList"].click()
        XCTAssertTrue(app.buttons["listenList.open.1"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["listenList.open.1"].label.contains("Novidade recente"))
        news.click()
        app.buttons["news.seen.11111111-1111-4111-8111-111111111111"].click()
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Novidades offline"; capture.lifetime = .keepAlways; add(capture)
        let expand = app.buttons["news.search.expand"]
        if expand.exists { expand.click() }
        let search = app.textFields["news.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("inexistente")
        XCTAssertTrue(app.staticTexts["Nenhuma novidade encontrada"].waitForExistence(timeout: 8))
        search.typeKey("a", modifierFlags: .command); search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        app.terminate(); app.launch()
        XCTAssertTrue(news.waitForExistence(timeout: 15)); news.click()
        XCTAssertTrue(app.buttons["Marcar como não vista"].firstMatch.waitForExistence(timeout: 8))
    }
}
