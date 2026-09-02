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

        let sectionIdentifiers = [
            "sidebar.home",
            "sidebar.songs",
            "sidebar.albums",
            "sidebar.artists",
            "sidebar.playlists",
            "sidebar.history",
        ]

        for identifier in sectionIdentifiers {
            XCTAssertTrue(
                app.buttons[identifier].waitForExistence(timeout: 3),
                "A seção \(identifier) não apareceu na barra lateral."
            )
        }
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

        let searchField = app.descendants(matching: .any)["search.field"]
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
    func testAppLaunchesOnHomeAndPlacesItBelowSearch() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let homePage = app.descendants(matching: .any)["home.page"]
        let searchButton = app.buttons["sidebar.search.open"]
        let homeButton = app.buttons["sidebar.home"]

        XCTAssertTrue(homePage.waitForExistence(timeout: 3))
        XCTAssertTrue(searchButton.waitForExistence(timeout: 3))
        XCTAssertTrue(homeButton.waitForExistence(timeout: 3))
        XCTAssertLessThan(searchButton.frame.minY, homeButton.frame.minY)
    }

    @MainActor
    func testHomeCardNavigatesToSongs() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let songsCard = app.buttons["home.songs"]
        XCTAssertTrue(songsCard.waitForExistence(timeout: 3))
        songsCard.click()

        XCTAssertTrue(app.buttons["sidebar.songs"].isSelected)
    }

    @MainActor
    func testQueueOpensWithoutGrowingWindowAndUsesResizableWidth() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let window = app.windows.firstMatch
        let queueButton = app.buttons["player.queue"]

        XCTAssertTrue(window.waitForExistence(timeout: 3))
        XCTAssertTrue(queueButton.waitForExistence(timeout: 3))
        XCTAssertLessThan(
            window.frame.maxX - queueButton.frame.maxX,
            80,
            "O botão da fila deve permanecer na extremidade direita da toolbar."
        )

        let windowWidthBefore = window.frame.width
        queueButton.click()

        let queue = app.descendants(matching: .any)["queue.sidebar"]
        XCTAssertTrue(queue.waitForExistence(timeout: 3))
        XCTAssertEqual(window.frame.width, windowWidthBefore, accuracy: 2)
        XCTAssertGreaterThanOrEqual(queue.frame.width, 260)
        XCTAssertLessThanOrEqual(queue.frame.width, 380)
        XCTAssertEqual(queueButton.label, "Ocultar fila")
        XCTAssertTrue(app.splitters.firstMatch.exists)
    }
}
