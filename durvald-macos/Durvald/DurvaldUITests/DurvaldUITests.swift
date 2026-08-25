import XCTest

final class DurvaldUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSidebarContainsMVPSections() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        XCTAssertTrue(app.staticTexts["Músicas"].exists)
        XCTAssertTrue(app.staticTexts["Álbuns"].exists)
        XCTAssertTrue(app.staticTexts["Artistas"].exists)
        XCTAssertTrue(app.staticTexts["Playlists"].exists)
        XCTAssertTrue(app.staticTexts["Histórico"].exists)
    }

    @MainActor
    func testPlayPauseStartsDisabledWithoutFixtureLibrary() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let button = app.buttons["player.playPause"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        XCTAssertFalse(button.isEnabled)
    }

    @MainActor
    func testNavigationShellControlsExist() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let sectionPicker = app.descendants(matching: .any)["sidebar.sectionPicker"]
        XCTAssertTrue(sectionPicker.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["sidebar.search.open"].exists)
        XCTAssertTrue(app.buttons["navigation.back"].exists)
        XCTAssertTrue(app.buttons["navigation.forward"].exists)
    }

    @MainActor
    func testSearchPageAutofocusesToolbarField() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let searchButton = app.buttons["sidebar.search.open"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        searchButton.click()

        let searchField = app.textFields["search.field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        XCTAssertEqual(
            searchField.value(forKey: "hasKeyboardFocus") as? Bool,
            true
        )

        searchField.typeText("__durvald_resultado_inexistente__")
        XCTAssertTrue(
            app.staticTexts["Nenhum resultado"]
                .waitForExistence(timeout: 3)
        )

        let clearButton = app.buttons["search.clear"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 3))
        clearButton.click()

        XCTAssertEqual(searchField.value as? String, "")
        XCTAssertEqual(
            searchField.value(forKey: "hasKeyboardFocus") as? Bool,
            true
        )
    }

    @MainActor
    func testQueueOpensInRightInspector() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let queueButton = app.buttons["player.queue"]
        XCTAssertTrue(queueButton.waitForExistence(timeout: 3))
        queueButton.click()

        XCTAssertTrue(app.staticTexts["Fila"].waitForExistence(timeout: 3))
        XCTAssertEqual(queueButton.label, "Ocultar fila")
    }
}
