import XCTest

final class AlbumMetadataUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAlbumInfoOpensOriginalTabbedWindowAndNavigatesAlbumTracks() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture", "--album-metadata-fixture", "-albums.minimumRating.halfSteps", "0"]
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["sidebar.albums"].waitForExistence(timeout: 12))
        app.buttons["sidebar.albums"].click()
        let album = app.buttons["album.1"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 8))
        album.rightClick()
        let info = app.menuItems["Info"]
        XCTAssertTrue(info.waitForExistence(timeout: 3)); info.click()
        XCTAssertTrue(app.buttons["trackInfo.save"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["batchMetadata.save"].exists)
        for tab in ["details", "artwork", "lyrics", "options", "file"] {
            XCTAssertTrue(app.buttons["trackInfo.tab.\(tab)"].exists)
        }
        let title = app.textFields["trackInfo.field.Título"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "value == %@", "Rating track 001"), evaluatedWith: title)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["trackInfo.next"].isEnabled)
        XCTAssertFalse(app.buttons["trackInfo.previous"].isEnabled)
        app.buttons["trackInfo.next"].click()
        expectation(for: NSPredicate(format: "value == %@", "Rating track 002"), evaluatedWith: title)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["trackInfo.previous"].isEnabled)
        XCTAssertFalse(app.buttons["trackInfo.next"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.windows["Info da faixa"].screenshot())
        screenshot.name = "Janela original de metadados"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
