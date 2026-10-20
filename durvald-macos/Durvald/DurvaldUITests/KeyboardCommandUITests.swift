import XCTest

final class KeyboardCommandUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testBatchInfoPreservesConfirmationAndAuxiliaryWindowScope() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture",
                                "-library.music.skipBatchInfoConfirmation", "NO", "-library.music.sort", "title"]
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["sidebar.songs"].waitForExistence(timeout: 12))
        app.typeKey("2", modifierFlags: .command)
        let table = app.tables["library.musicTable"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let first = table.tableRows.element(boundBy: 0)
        let second = table.tableRows.element(boundBy: 1)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click()
        app.typeKey(.downArrow, modifierFlags: .shift)
        XCTAssertTrue(first.isSelected)
        XCTAssertTrue(second.isSelected)
        app.typeKey("i", modifierFlags: .command)
        let edit = app.sheets.buttons["Editar faixas"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        app.sheets.buttons["Cancelar"].firstMatch.click()
        XCTAssertFalse(app.staticTexts["Editar metadados de 2 faixas"].exists)
        app.typeKey("i", modifierFlags: .command)
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        let heading = app.staticTexts["Editar metadados de 2 faixas"]
        XCTAssertTrue(heading.waitForExistence(timeout: 8))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(heading.exists)
        XCTAssertTrue(table.exists, "Comando da janela auxiliar não deve navegar a janela principal")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(heading.exists)
        XCTAssertTrue(table.exists)
    }

    @MainActor
    func testRepeatedPlaylistOccurrenceRetainsKeyboardFocusAfterMove() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--playback-clock-fixture",
                                "--collection-play-fixture", "--duplicate-playlist-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["sidebar.songs"].waitForExistence(timeout: 8))
        app.typeKey("5", modifierFlags: .command)
        let playlist = app.descendants(matching: .any)["playlist.7"].firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        playlist.click()
        XCTAssertTrue(app.descendants(matching: .any)["playlist.detail.7"].waitForExistence(timeout: 5))
        let occurrences = app.descendants(matching: .any).matching(identifier: "playlist.track.100")
        XCTAssertEqual(occurrences.count, 2)
        let selected = occurrences.element(boundBy: 1)
        selected.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).click()
        app.typeKey(.return, modifierFlags: [])
        app.buttons["sidebar.home"].hover()
        XCTAssertTrue(selected.descendants(matching: .any)["album.track.100.playbackIndicator"].waitForExistence(timeout: 4))
        XCTAssertFalse(occurrences.element(boundBy: 0).descendants(matching: .any)["album.track.100.playbackIndicator"].exists)
        app.typeKey(.upArrow, modifierFlags: [.command, .control])
        app.typeKey(.return, modifierFlags: [])
        app.buttons["sidebar.home"].hover()
        let moved = occurrences.element(boundBy: 1)
        XCTAssertTrue(moved.descendants(matching: .any)["album.track.100.playbackIndicator"].waitForExistence(timeout: 5))
        XCTAssertFalse(occurrences.element(boundBy: 0).descendants(matching: .any)["album.track.100.playbackIndicator"].exists)
    }
}
