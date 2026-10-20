import XCTest

final class ArtworkPreviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAlbumCoverOpensAtWindowRelativeHeightAndCloses() {
        let app = launchFixture()
        defer { app.terminate() }
        app.links["player.trackTitle"].click()
        let cover = app.descendants(matching: .any)["album.header.artwork"].firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        let windowHeight = app.windows.firstMatch.frame.height
        cover.click()
        verifyPreview(app, windowHeight: windowHeight)
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Capa ampliada do álbum"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["artwork.preview.close"].click()
        XCTAssertFalse(app.buttons["artwork.preview.close"].exists)
        XCTAssertTrue(cover.exists)
    }

    @MainActor
    func testPlaylistCoverPreservesAspectRatioAndEscapeCloses() {
        let app = launchFixture()
        defer { app.terminate() }
        app.typeKey("5", modifierFlags: .command)
        let playlist = app.descendants(matching: .any)["playlist.7"].firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        playlist.click()
        let cover = app.buttons["playlist.header.artwork"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        let windowHeight = app.windows.firstMatch.frame.height
        cover.click()
        verifyPreview(app, windowHeight: windowHeight)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["artwork.preview.close"].exists)
        XCTAssertTrue(cover.exists)
    }

    @MainActor
    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--playback-clock-fixture",
                                "--collection-play-fixture", "--artwork-preview-fixture"]
        app.launch()
        XCTAssertTrue(app.links["player.trackTitle"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor
    private func verifyPreview(_ app: XCUIApplication, windowHeight: CGFloat) {
        XCTAssertTrue(app.buttons["artwork.preview.close"].waitForExistence(timeout: 5))
        let image = app.descendants(matching: .any)["artwork.preview.image"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        expectation(for: NSPredicate { _, _ in
            abs(image.frame.width / max(1, image.frame.height) - 1.5) < 0.02
        }, evaluatedWith: image)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(image.frame.height, windowHeight * 0.65, accuracy: 2)
    }
}
