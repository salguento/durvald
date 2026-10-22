import XCTest

final class PersonalTagUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch(_ fixtureID: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture", "-library.music.onlyFavorites", "NO", "-albums.minimumRating.halfSteps", "0"]
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = fixtureID
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.songs"].waitForExistence(timeout: 12))
        return app
    }

    @MainActor
    private func filter(_ name: String, app: XCUIApplication) {
        app.descendants(matching: .any)["personalTags.filter"].firstMatch.click()
        let item = app.menuItems[name].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 4))
        item.click()
    }

    @MainActor
    private func create(_ name: String, app: XCUIApplication) {
        let field = app.textFields["personalTags.input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click(); field.typeText(name)
        app.buttons["personalTags.create"].click()
        let toggle = app.checkBoxes[name]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: app.buttons["personalTags.done"])
        waitForExpectations(timeout: 5)
        app.buttons["personalTags.done"].click()
    }

    @MainActor
    func testBatchTrackTagsFilterRenameAndGlobalDelete() {
        let app = launch(UUID().uuidString)
        defer { app.terminate() }
        app.typeKey("2", modifierFlags: .command)
        let table = app.tables["library.musicTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        table.tableRows.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        app.typeKey(.downArrow, modifierFlags: .shift)
        app.buttons["personalTags.editBatch"].click()
        create("Noite", app: app)
        filter("Noite", app: app)
        expectation(for: NSPredicate { _, _ in table.tableRows.count == 2 }, evaluatedWith: table)
        waitForExpectations(timeout: 5)
        filter("Gerenciar tags…", app: app)
        let name = app.textFields["personalTags.name.1"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); app.typeKey("a", modifierFlags: .command); name.typeText("Noturno")
        app.buttons["personalTags.rename.1"].click()
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: app.buttons["personalTags.rename.1"])
        waitForExpectations(timeout: 5)
        app.buttons["personalTags.managerDone"].click()
        XCTAssertEqual(table.tableRows.count, 2, "Renomear deve preservar o filtro por identidade")
        filter("Gerenciar tags…", app: app)
        app.buttons["personalTags.delete.1"].click()
        app.sheets.buttons["Cancelar"].firstMatch.click()
        XCTAssertTrue(app.textFields["personalTags.name.1"].exists)
        app.buttons["personalTags.delete.1"].click()
        app.sheets.buttons["Excluir de todos"].firstMatch.click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.textFields["personalTags.name.1"])
        waitForExpectations(timeout: 5)
        app.buttons["personalTags.managerDone"].click()
        expectation(for: NSPredicate { _, _ in table.tableRows.count == 7 }, evaluatedWith: table)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testReleaseTagsRemainSeparateFromTracksAndPersistAfterRelaunch() {
        let fixtureID = UUID().uuidString
        let app = launch(fixtureID)
        defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        let album = app.buttons["album.1"]
        XCTAssertTrue(album.waitForExistence(timeout: 5)); album.click()
        let edit = app.buttons["personalTags.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.click()
        create("Viagem", app: app)
        XCTAssertTrue(app.staticTexts["personalTags.chip.1"].exists)
        app.typeKey("2", modifierFlags: .command)
        let table = app.tables["library.musicTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        filter("Viagem", app: app)
        expectation(for: NSPredicate { _, _ in table.tableRows.count == 0 }, evaluatedWith: table)
        waitForExpectations(timeout: 5)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.songs"].waitForExistence(timeout: 12))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["album.1"].waitForExistence(timeout: 5))
        filter("Viagem", app: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["album.2"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["album.1"].exists)
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Álbuns filtrados por tags pessoais"; capture.lifetime = .keepAlways; add(capture)
    }
}
