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
}
