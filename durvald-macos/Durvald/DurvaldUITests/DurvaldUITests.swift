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
        XCTAssertTrue(app.textFields["sidebar.search"].exists)
        XCTAssertTrue(app.buttons["sidebar.settings"].exists)
        XCTAssertTrue(app.buttons["navigation.back"].exists)
        XCTAssertTrue(app.buttons["navigation.forward"].exists)
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
