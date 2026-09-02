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
    func testPlayerMetadataHasIndependentContextMenus() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let artwork = app.buttons["player.artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 3))

        artwork.rightClick()
        XCTAssertTrue(app.menuItems["Reproduzir álbum"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.menuItems["Favoritar faixa"].exists)
        app.menuItems["Abrir álbum"].click()
        XCTAssertTrue(app.descendants(matching: .any)["album.detail.42"].waitForExistence(timeout: 3))

        app.links["player.trackTitle"].rightClick()
        XCTAssertTrue(app.menuItems["Favoritar faixa"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Adicionar à fila"].exists)
        XCTAssertFalse(app.menuItems["Reproduzir álbum"].exists)
        app.typeKey(.escape, modifierFlags: [])

        app.links["player.artist"].rightClick()
        XCTAssertTrue(app.menuItems["Copiar nome do artista"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.menuItems["Adicionar à fila"].exists)
        app.menuItems["Abrir artista"].click()
        XCTAssertTrue(app.descendants(matching: .any)["artist.detail.7"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testCompactPlayerShowsTrackTooltipOnHover() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--long-player-metadata"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -600, dy: 0)))

        let artwork = app.buttons["player.artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 3))
        XCTAssertTrue(app.links["player.trackTitle"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.links["player.artist"].exists)
        let tooltip = app.descendants(matching: .any)["player.trackTooltip"].firstMatch
        XCTAssertFalse(tooltip.exists)
        artwork.hover()
        XCTAssertTrue(tooltip.waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Compact player tooltip"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(tooltip.value as? String, "Faixa de teste com título extenso — gravação ao vivo e versão completa\nArtista de teste com nome extenso e convidados especiais")
        XCTAssertLessThan(tooltip.frame.maxY, artwork.frame.minY)

        app.buttons["sidebar.home"].hover()
        XCTAssertTrue(tooltip.waitForNonExistence(timeout: 2))
        artwork.click()
        XCTAssertTrue(app.descendants(matching: .any)["album.detail.42"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLongPlayerMetadataScrollsWithoutMovingItsLinks() async throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--long-player-metadata"]
        app.launch()

        let title = app.links["player.trackTitle"]
        let artist = app.links["player.artist"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertTrue(artist.exists)
        app.buttons["sidebar.home"].hover()

        let titleFrame = title.frame
        let artistFrame = artist.frame
        let favorite = app.buttons["player.favorite"]
        let options = app.descendants(matching: .any)["player.options"].firstMatch
        XCTAssertTrue(favorite.exists)
        XCTAssertTrue(options.exists)
        XCTAssertGreaterThanOrEqual(favorite.frame.minX, max(titleFrame.maxX, artistFrame.maxX))
        XCTAssertEqual(favorite.frame.midX, options.frame.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(favorite.frame.maxY, options.frame.minY)
        let playerAttachment = XCTAttachment(screenshot: app.screenshot())
        playerAttachment.name = "Player actions beside long metadata"
        playerAttachment.lifetime = .keepAlways
        add(playerAttachment)
        let titleBefore = title.screenshot()
        let artistBefore = artist.screenshot()
        try await Task.sleep(for: .seconds(3))
        let titleAfter = title.screenshot()
        let artistAfter = artist.screenshot()

        XCTAssertEqual(title.frame, titleFrame)
        XCTAssertEqual(artist.frame, artistFrame)
        XCTAssertNotEqual(titleBefore.pngRepresentation, titleAfter.pngRepresentation)
        XCTAssertNotEqual(artistBefore.pngRepresentation, artistAfter.pngRepresentation)
        XCTAssertEqual(title.label, "Faixa de teste com título extenso — gravação ao vivo e versão completa")
        XCTAssertEqual(artist.label, "Artista de teste com nome extenso e convidados especiais")

        for (name, screenshot) in [("Title before", titleBefore), ("Title scrolling", titleAfter),
                                   ("Artist before", artistBefore), ("Artist scrolling", artistAfter)] {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        options.click()
        XCTAssertTrue(app.menuItems["Adicionar à fila"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])

        title.click()
        XCTAssertTrue(app.descendants(matching: .any)["album.detail.42"].waitForExistence(timeout: 3))
        artist.click()
        XCTAssertTrue(app.descendants(matching: .any)["artist.detail.7"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testPlayerMetadataNavigatesToReferencedAlbumAndArtist() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()

        let title = app.links["player.trackTitle"]
        let artwork = app.buttons["player.artwork"]
        let artist = app.links["player.artist"]
        let back = app.buttons["navigation.back"]
        let forward = app.buttons["navigation.forward"]
        let albumPage = app.descendants(matching: .any)["album.detail.42"]
        let artistPage = app.descendants(matching: .any)["artist.detail.7"]

        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.hover()
        title.click()
        XCTAssertTrue(albumPage.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["album.detail.43"].exists)
        back.click()
        XCTAssertTrue(app.descendants(matching: .any)["home.page"].waitForExistence(timeout: 3))

        artwork.click()
        XCTAssertTrue(albumPage.waitForExistence(timeout: 3))
        artist.hover()
        artist.click()
        XCTAssertTrue(artistPage.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["artist.detail.8"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["artist.detail.9"].exists)
        XCTAssertTrue(app.buttons["album.42"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["artist.track.100"].exists)

        back.click()
        XCTAssertTrue(albumPage.waitForExistence(timeout: 3))
        forward.click()
        XCTAssertTrue(artistPage.waitForExistence(timeout: 3))
        app.buttons["album.42"].click()
        XCTAssertTrue(albumPage.waitForExistence(timeout: 3))
    }

    @MainActor
    func testPlayPauseStartsDisabledWithoutFixtureLibrary() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let button = app.buttons["player.playPause"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        XCTAssertFalse(button.isEnabled)
        XCTAssertFalse(app.buttons["player.artwork"].isEnabled)
        XCTAssertFalse(app.buttons["player.trackTitle"].exists)
        XCTAssertFalse(app.buttons["player.artist"].exists)
        XCTAssertFalse(app.links["player.trackTitle"].exists)
        XCTAssertFalse(app.links["player.artist"].exists)
    }

    @MainActor
    func testVolumeMuteRestoresLevelAndIconTracksSlider() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let volume = app.sliders["player.volume"]
        let mute = app.buttons["player.mute"]
        XCTAssertTrue(volume.waitForExistence(timeout: 3))
        XCTAssertTrue(mute.exists)
        let originalVolume = volume.value as? NSNumber
        XCTAssertNotNil(originalVolume)

        mute.click()
        XCTAssertEqual((volume.value as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual(mute.value as? String, "Mudo")
        XCTAssertEqual(mute.label, "Desmutar volume")

        mute.click()
        XCTAssertEqual(volume.value as? NSNumber, originalVolume)
        XCTAssertEqual(mute.label, "Mutar volume")

        for (fraction, level) in [(0.2, "baixo"), (0.5, "médio"), (0.85, "alto")] {
            volume.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).click()
            XCTAssertTrue((mute.value as? String)?.contains(level) == true)
        }

        volume.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: volume.coordinate(withNormalizedOffset: CGVector(dx: -0.2, dy: 0.5))
            )
        XCTAssertEqual((volume.value as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual(mute.value as? String, "Sem volume")
        mute.click()
        XCTAssertGreaterThan((volume.value as? NSNumber)?.doubleValue ?? 0, 0)

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Volume control"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testProgressHoverKeepsPlayerLayoutStable() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let progress = app.sliders["player.progress"]
        let playPause = app.buttons["player.playPause"]
        let elapsed = app.staticTexts["player.elapsed"]
        let duration = app.staticTexts["player.duration"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        XCTAssertFalse(progress.isEnabled)
        XCTAssertTrue(elapsed.exists)
        XCTAssertTrue(duration.exists)
        XCTAssertEqual(elapsed.frame.midY, progress.frame.midY, accuracy: 1)
        XCTAssertEqual(duration.frame.midY, progress.frame.midY, accuracy: 1)
        XCTAssertLessThan(elapsed.frame.maxX, progress.frame.minX)
        XCTAssertGreaterThan(duration.frame.minX, progress.frame.maxX)

        let progressFrame = progress.frame
        let controlsFrame = playPause.frame
        let windowFrame = app.windows.firstMatch.frame
        let resting = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        resting.name = "Progress resting"
        resting.lifetime = .keepAlways
        add(resting)

        progress.hover()

        XCTAssertEqual(progress.frame, progressFrame)
        XCTAssertEqual(playPause.frame, controlsFrame)
        XCTAssertEqual(app.windows.firstMatch.frame, windowFrame)
        let hovered = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        hovered.name = "Progress hovered"
        hovered.lifetime = .keepAlways
        add(hovered)
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

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Player and queue appearance"
        attachment.lifetime = .keepAlways
        add(attachment)

        queueButton.click()
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: queue
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)
        XCTAssertEqual(window.frame.width, windowWidthBefore, accuracy: 2)

        queueButton.click()
        XCTAssertTrue(queue.waitForExistence(timeout: 3))
        XCTAssertEqual(window.frame.width, windowWidthBefore, accuracy: 2)
    }
}
