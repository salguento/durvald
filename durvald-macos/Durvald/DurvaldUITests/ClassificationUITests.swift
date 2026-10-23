import XCTest

final class ClassificationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture", "--classification-fixture", "-albums.minimumRating.halfSteps", "0"]
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["sidebar.genres"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor private func title(in app: XCUIApplication) -> String {
        let text = app.staticTexts["classification.title"]
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        return (text.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text.label
    }
    @MainActor private func tab(_ name: String, in app: XCUIApplication) {
        app.descendants(matching: .any)["classification.tabs"].firstMatch.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch.click()
    }
    @MainActor private func openClassificationInfo(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["classification.link.genre.1"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["classification.link.style.1"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["classification.edit.genre"].exists)
        XCTAssertFalse(app.buttons["classification.edit.style"].exists)
        let cover = app.buttons["album.header.artwork"].firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 8)); cover.rightClick()
        app.menuItems["Info"].click()
        let genres = app.buttons["trackInfo.tab.classification"]
        XCTAssertTrue(genres.waitForExistence(timeout: 8)); genres.click()
    }
    @MainActor func testGenreStyleContentAndHistory() {
        let app = launch(); defer { app.terminate() }
        app.buttons["sidebar.genres"].click()
        let electronic = app.buttons["classification.term.genre.1"]
        XCTAssertTrue(electronic.waitForExistence(timeout: 8)); electronic.click()
        XCTAssertTrue(app.staticTexts["classification.title"].waitForExistence(timeout: 8))
        XCTAssertEqual(title(in: app), "Electronic")
        XCTAssertTrue(app.scrollViews["classification.wellRated"].exists)
        app.buttons["classification.related.style.1"].click()
        XCTAssertEqual(title(in: app), "Ambient")
        app.buttons["navigation.back"].click()
        XCTAssertEqual(title(in: app), "Electronic")
        tab("Músicas", in: app)
        XCTAssertTrue(app.staticTexts["Rating track 001"].waitForExistence(timeout: 5))
        tab("Artistas", in: app)
        let artist = app.buttons["classification.artist.1"]
        XCTAssertTrue(artist.waitForExistence(timeout: 5)); artist.click()
        XCTAssertTrue(app.buttons["classification.link.genre.1"].waitForExistence(timeout: 8))
        app.buttons["navigation.back"].click()
        XCTAssertTrue(artist.waitForExistence(timeout: 5))
        tab("Álbuns", in: app)
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Gêneros e estilos"; capture.lifetime = .keepAlways; add(capture)
        app.scrollViews["classification.page"].scroll(byDeltaX: 0, deltaY: -480)
        let album = app.buttons["album.1"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        let albumsCapture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        albumsCapture.name = "Álbuns do gênero"; albumsCapture.lifetime = .keepAlways; add(albumsCapture)
        album.click()
        openClassificationInfo(in: app)
        XCTAssertTrue(app.buttons["classification.link.genre.1"].waitForExistence(timeout: 5))
    }
    @MainActor func testInfoStyleEditingAndRelaunchPersistence() {
        let app = launch(); defer { app.terminate() }
        app.typeKey("3", modifierFlags: .command)
        let album = app.buttons["album.1"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 8)); album.click()
        openClassificationInfo(in: app)
        let edit = app.buttons["classification.edit.style"]
        XCTAssertTrue(edit.waitForExistence(timeout: 8)); edit.click()
        let names = app.textViews["classification.editor.names"]
        XCTAssertTrue(names.waitForExistence(timeout: 5)); names.click()
        app.typeKey("a", modifierFlags: .command); names.typeText("Dream Pop")
        app.buttons["classification.editor.save"].click()
        XCTAssertTrue(app.windows["Info da faixa"].buttons["Fechar"].waitForExistence(timeout: 5))
        app.windows["Info da faixa"].buttons["Fechar"].click()
        app.buttons["sidebar.genres"].click()
        let dream = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "classification.term.style.", "Dream Pop")).firstMatch
        XCTAssertTrue(dream.waitForExistence(timeout: 8)); dream.click()
        XCTAssertEqual(title(in: app), "Dream Pop")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["sidebar.genres"].waitForExistence(timeout: 15)); app.buttons["sidebar.genres"].click()
        XCTAssertTrue(dream.waitForExistence(timeout: 8))
        app.buttons["classification.unclassified"].click()
        XCTAssertTrue(app.staticTexts["classification.title"].waitForExistence(timeout: 8))
        XCTAssertEqual(title(in: app), "Sem gênero")
    }
}
