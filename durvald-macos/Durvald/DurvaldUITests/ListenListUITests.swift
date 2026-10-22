import XCTest

final class ListenListUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor
    private func launch(online: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture", "-albums.minimumRating.halfSteps", "0"]
        if online { app.launchArguments.append("--listen-list-external-fixture") }
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.listenList"].waitForExistence(timeout: 12))
        return app
    }
    @MainActor
    func testHomeSidebarSaveHeardUndoAndRelaunch() {
        let app = launch()
        defer { app.terminate() }
        let home = app.buttons["sidebar.home"], list = app.buttons["sidebar.listenList"]
        XCTAssertLessThan(home.frame.minY, list.frame.minY)
        XCTAssertLessThan(list.frame.minY, app.buttons["sidebar.retrospective"].frame.minY)
        let card = app.buttons["home.listenList"]
        XCTAssertTrue(card.waitForExistence(timeout: 5)); card.click()
        XCTAssertTrue(app.descendants(matching: .any)["listenList.page"].waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        let album = app.buttons["album.1"]
        XCTAssertTrue(album.waitForExistence(timeout: 5)); album.rightClick()
        app.menuItems["Adicionar a Para ouvir"].click()
        list.click()
        let row = app.descendants(matching: .any)["listenList.entry.1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["listenList.heard.1"].click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row); waitForExpectations(timeout: 5)
        app.descendants(matching: .any)["listenList.status"].firstMatch.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Ouvidos")).firstMatch.click()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["listenList.heard.1"].click()
        app.descendants(matching: .any)["listenList.status"].firstMatch.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Para ouvir")).firstMatch.click()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["sidebar.listenList"].waitForExistence(timeout: 12)); app.buttons["sidebar.listenList"].click()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Para ouvir"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["listenList.remove.1"].click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row); waitForExpectations(timeout: 5)
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["album.1"].waitForExistence(timeout: 5))
    }
    @MainActor
    func testOnlineReferenceNeedsNoLocalAudioAndCanBeMarkedHeard() {
        let app = launch(online: true)
        defer { app.terminate() }
        app.buttons["sidebar.listenList"].click()
        let online = app.buttons["listenList.open.1"]
        XCTAssertTrue(online.waitForExistence(timeout: 5))
        XCTAssertTrue(online.label.contains("Online listening fixture"))
        XCTAssertTrue(online.label.contains("Somente on-line"))
        app.buttons["listenList.heard.1"].click()
        app.descendants(matching: .any)["listenList.status"].firstMatch.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Ouvidos")).firstMatch.click()
        XCTAssertTrue(online.waitForExistence(timeout: 5))
    }
}
