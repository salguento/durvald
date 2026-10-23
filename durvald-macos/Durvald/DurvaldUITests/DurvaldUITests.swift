import XCTest
import AppKit

final class DurvaldUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testKeyboardSelectionAndCollectionPlaybackUseFocusedTargets() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--playback-clock-fixture", "--collection-play-fixture", "-library.music.sort", "title", "-library.music.sortAscending", "YES", "-library.music.onlyFavorites", "NO", "-library.music.groupArtwork", "NO"]
        app.launch()
        app.typeKey("2", modifierFlags: .command)
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        let third = table.tableRows.element(boundBy: 2)
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        third.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        XCTAssertTrue(third.isSelected)
        app.typeKey(.return, modifierFlags: [])
        let title = app.links["player.trackTitle"]
        expectation(for: NSPredicate(format: "label == %@", "Faixa de teste 3"), evaluatedWith: title)
        waitForExpectations(timeout: 4)
        app.typeKey(.space, modifierFlags: [])
        expectation(for: NSPredicate(format: "label == %@", "Reproduzir"), evaluatedWith: app.buttons["player.playPause"])
        waitForExpectations(timeout: 4)
        app.typeKey("3", modifierFlags: .command)
        let album = app.buttons["album.42"]
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.click()
        XCTAssertTrue(app.buttons["collection.play"].waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: .command)
        expectation(for: NSPredicate(format: "label == %@", "Faixa de teste 1"), evaluatedWith: title)
        waitForExpectations(timeout: 4)
        XCTAssertEqual(app.buttons["player.playPause"].label, "Pausar")
    }

    @MainActor
    func testTabReachesSlidersAndProtectsTheirSpaceKey() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--playback-clock-fixture", "--collection-play-fixture", "-AppleKeyboardUIMode", "3"]
        app.launch()
        XCTAssertTrue(app.sliders["player.progress"].waitForExistence(timeout: 5))
        let progress = app.sliders["player.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        app.typeKey("k", modifierFlags: .command)
        app.typeKey(.escape, modifierFlags: [])
        func reach(_ element: XCUIElement) -> Bool {
            for _ in 0..<45 {
                app.typeKey(.tab, modifierFlags: [])
                if element.value(forKey: "hasKeyboardFocus") as? Bool == true { return true }
            }
            return false
        }
        XCTAssertTrue(reach(progress), "Tab deve alcançar o slider de progresso")
        let before = app.buttons["player.playPause"].label
        app.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(app.buttons["player.playPause"].label, before)
        let volume = app.sliders["player.volume"]
        XCTAssertTrue(reach(volume), "Tab deve alcançar o slider de volume")
        app.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(app.buttons["player.playPause"].label, before)
    }

    @MainActor
    func testKeyboardCommandsProtectTextAndExposeHelp() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--playback-clock-fixture", "--collection-play-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["player.playPause"].waitForExistence(timeout: 5))
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("dois nomes")
        XCTAssertEqual(field.value as? String, "dois nomes")
        XCTAssertEqual(app.buttons["player.playPause"].label, "Pausar")
        app.typeKey(.leftArrow, modifierFlags: .command)
        field.typeText("X")
        XCTAssertEqual(field.value as? String, "Xdois nomes")
        XCTAssertTrue(app.descendants(matching: .any)["home.page"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.buttons["album.42"].waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        let filter = app.textFields["albums.search.field"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["home.page"].waitForExistence(timeout: 5))
        app.typeKey("/", modifierFlags: [.command, .option])
        XCTAssertTrue(app.descendants(matching: .any)["keyboardShortcuts.help"].waitForExistence(timeout: 5))
        let helpCapture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        helpCapture.name = "Ajuda de atalhos"
        helpCapture.lifetime = .keepAlways
        add(helpCapture)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.descendants(matching: .any)["keyboardShortcuts.help"].exists)
        app.typeKey("m", modifierFlags: [.command, .shift])
        app.typeKey("m", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["player.playPause"].exists)
    }

    @MainActor
    func testHomeShelvesScrollWithPanelsAndOpenAlbums() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--scroll-effect-fixture", "--home-library-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Fill"].click()
        if !app.buttons["sidebar.home"].isHittable { app.buttons["navigation.sidebar"].click() }
        app.buttons["sidebar.home"].click()
        let recent = app.descendants(matching: .any)["home.recentlyPlayed"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        let first = recent.buttons["album.42"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(first.isHittable)
        let initialX = first.frame.minX
        app.buttons["player.queue"].click()
        XCTAssertTrue(app.descendants(matching: .any)["queue.sidebar"].waitForExistence(timeout: 3))
        first.scroll(byDeltaX: -450, deltaY: 0)
        XCTAssertLessThan(first.frame.minX, initialX - 50)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Home shelves beneath both side panels"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Return to the first card and open it using the existing album route.
        recent.scroll(byDeltaX: 1500, deltaY: 0)
        XCTAssertTrue(first.isHittable)
        first.click()
        XCTAssertTrue(app.buttons["collection.play"].waitForExistence(timeout: 5))
        app.buttons["navigation.back"].click()
        XCTAssertTrue(app.buttons["home.history"].waitForExistence(timeout: 5))
        app.buttons["home.history"].click()
        XCTAssertTrue(app.descendants(matching: .any)["retrospective.tabs"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSidebarToolbarShowsHomeOnlyWhenCollapsedAndPreservesHistory() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Fill"].click()
        let sidebar = app.buttons["navigation.sidebar"]
        let home = app.buttons["navigation.home"]
        if !app.buttons["sidebar.songs"].isHittable { sidebar.click() }
        XCTAssertTrue(app.buttons["sidebar.songs"].waitForExistence(timeout: 3))
        XCTAssertTrue(sidebar.isHittable)
        XCTAssertFalse(home.exists)
        XCTAssertFalse(app.buttons["library.addMenu"].exists)
        app.buttons["sidebar.songs"].click()
        sidebar.click()
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertTrue(home.isHittable)
        XCTAssertFalse(app.buttons["sidebar.songs"].exists)
        let history = app.descendants(matching: .any)["navigation.history"]
        XCTAssertLessThanOrEqual(sidebar.frame.maxX, home.frame.minX)
        XCTAssertLessThan(home.frame.maxX, history.frame.minX)
        XCTAssertEqual(window.frame.maxX - app.buttons["player.queue"].frame.maxX, 8, accuracy: 1)

        // Click inside the glass circle, outside the house icon.
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click()
        XCTAssertTrue(app.descendants(matching: .any)["home.page"].waitForExistence(timeout: 3))
        XCTAssertTrue(home.exists)
        app.buttons["navigation.back"].click()
        XCTAssertTrue(app.descendants(matching: .any)["library.summary"].waitForExistence(timeout: 3))
        app.buttons["navigation.forward"].click()
        XCTAssertTrue(app.descendants(matching: .any)["home.page"].waitForExistence(timeout: 3))
        let capture = XCTAttachment(screenshot: window.screenshot())
        capture.name = "Collapsed sidebar with home navigation"
        capture.lifetime = .keepAlways
        add(capture)

        sidebar.click()
        XCTAssertTrue(app.buttons["sidebar.songs"].waitForExistence(timeout: 3))
        XCTAssertFalse(home.exists)
        XCTAssertFalse(app.buttons["library.addMenu"].exists)
    }

    @MainActor
    func testToolbarHistoryStaysVisibleWithSidebarAndSpaceAvailable() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Fill"].click()
        if !app.buttons["sidebar.songs"].isHittable {
            app.buttons["navigation.sidebar"].click()
        }

        let back = app.buttons["navigation.back"]
        let forward = app.buttons["navigation.forward"]
        for destination in ["songs", "home", "albums", "home"] {
            app.buttons["sidebar.\(destination)"].click()
            for button in [back, forward, app.buttons["player.queue"]] {
                XCTAssertTrue(button.isHittable, "\(button.identifier) must stay out of overflow on \(destination)")
                XCTAssertTrue(window.frame.contains(button.frame))
            }
        }
        back.click()
        XCTAssertTrue(app.descendants(matching: .any)["albums.summary"].waitForExistence(timeout: 3))
        forward.click()
        XCTAssertTrue(app.descendants(matching: .any)["home.page"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testToolbarNavigationStaysVisibleAfterResizingWithSidebarCollapsed() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        if app.buttons["sidebar.songs"].exists { app.buttons["navigation.sidebar"].click() }
        for _ in 0..<2 {
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Move & Resize"].click()
            app.menuItems["Left"].click()
            app.activate()
            app.typeKey(.escape, modifierFlags: [])
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Fill"].click()
            for identifier in ["navigation.sidebar", "navigation.home", "player.queue"] {
                let button = app.buttons[identifier]
                XCTAssertTrue(button.waitForExistence(timeout: 3))
                XCTAssertTrue(button.isHittable, "\(identifier) must stay out of overflow when space is available")
                XCTAssertTrue(window.frame.contains(button.frame))
            }
            let history = app.descendants(matching: .any)["navigation.history"]
            XCTAssertTrue(history.exists)
            XCTAssertGreaterThan(history.frame.width, 50)
            XCTAssertTrue(window.frame.contains(history.frame))
            XCTAssertEqual(window.frame.maxX - app.buttons["player.queue"].frame.maxX, 8, accuracy: 1)
            XCTAssertEqual(app.buttons["navigation.sidebar"].label, "Mostrar barra lateral")
            XCTAssertEqual(app.buttons["player.queue"].label, "Mostrar fila")
            app.buttons["player.queue"].click()
            XCTAssertEqual(app.buttons["player.queue"].label, "Ocultar fila")
            app.buttons["player.queue"].click()
        }
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
            "sidebar.retrospective",
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
        XCTAssertFalse(app.menuItems["Tocar"].exists)
        XCTAssertTrue(app.menuItems["Adicionar à playlist"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        artwork.click()
        XCTAssertTrue(app.descendants(matching: .any)["album.detail.42"].waitForExistence(timeout: 3))

        app.links["player.trackTitle"].rightClick()
        XCTAssertTrue(app.menuItems["Favoritar"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Adicionar à fila"].exists)
        for title in ["Tocar de próxima", "Ir ao artista", "Ir ao álbum", "Ir à playlist", "Info", "Compartilhar"] {
            XCTAssertTrue(app.menuItems[title].exists, "Ação ausente: \(title)")
        }
        XCTAssertFalse(app.menuItems["Reproduzir agora"].exists)
        app.menuItems["Compartilhar"].hover()
        XCTAssertTrue(app.menuItems["Copiar nome"].waitForExistence(timeout: 2))
        let addToPlaylist = app.menuItems["Adicionar à playlist"]
        XCTAssertTrue(addToPlaylist.exists)
        addToPlaylist.hover()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 2))
        XCTAssertEqual(app.searchFields.firstMatch.placeholderValue, "Pesquisar playlists")
        XCTAssertFalse(app.menuItems["Reproduzir álbum"].exists)
        app.typeKey(.escape, modifierFlags: [])

        app.links["player.artist"].rightClick()
        XCTAssertTrue(app.menuItems["Copiar nome do artista"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.menuItems["Adicionar à fila"].exists)
        app.menuItems["Abrir artista"].click()
        XCTAssertTrue(app.descendants(matching: .any)["artist.detail.7"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testCompactPlayerKeepsMetadataWithoutArtworkTooltip() {
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
        XCTAssertTrue(app.links["player.trackTitle"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.links["player.artist"].exists)
        let tooltip = app.descendants(matching: .any)["player.trackTooltip"].firstMatch
        XCTAssertFalse(tooltip.exists)
        artwork.hover()
        XCTAssertFalse(tooltip.waitForExistence(timeout: 1))
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Compact player without artwork tooltip"
        attachment.lifetime = .keepAlways
        add(attachment)
        artwork.click()
        XCTAssertTrue(app.descendants(matching: .any)["album.detail.42"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLongPlayerMetadataScrollsWithoutMovingItsLinks() async throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture",
                                "--long-player-metadata", "--playback-clock-fixture"]
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
        let volume = app.sliders["player.volume"]
        let progress = app.sliders["player.progress"]
        let artwork = app.buttons["player.artwork"]
        XCTAssertTrue(favorite.exists)
        XCTAssertTrue(options.exists)
        XCTAssertTrue(volume.exists)
        XCTAssertTrue(progress.exists)
        XCTAssertTrue(artwork.exists)
        XCTAssertGreaterThanOrEqual(progress.frame.minY, artistFrame.maxY)
        XCTAssertEqual(progress.frame.maxY, artwork.frame.maxY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(favorite.frame.minX, max(titleFrame.maxX, artistFrame.maxX))
        XCTAssertLessThanOrEqual(favorite.frame.maxX, options.frame.minX)
        XCTAssertEqual(favorite.frame.midY, options.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(options.frame.maxX, volume.frame.minX)
        let playerAttachment = XCTAttachment(screenshot: app.screenshot())
        playerAttachment.name = "Player actions beside volume"
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

        let back = app.buttons["navigation.back"]
        let forward = app.buttons["navigation.forward"]
        let albumPage = app.descendants(matching: .any)["album.detail.42"]
        let artistPage = app.descendants(matching: .any)["artist.detail.7"]

        let title = app.links["player.trackTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.hover()
        title.click()
        XCTAssertTrue(albumPage.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["album.detail.43"].exists)
        let pausedTrackNumber = app.staticTexts["album.track.100.number"]
        XCTAssertTrue(pausedTrackNumber.waitForExistence(timeout: 3))
        XCTAssertFalse(app.images["album.track.100.playbackIndicator"].exists)
        let albumCapture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        albumCapture.name = "Album active track indicator"
        albumCapture.lifetime = .keepAlways
        add(albumCapture)
        back.click()
        XCTAssertTrue(app.descendants(matching: .any)["home.page"].waitForExistence(timeout: 3))

        let artwork = app.buttons["player.artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 3))
        artwork.click()
        XCTAssertTrue(albumPage.waitForExistence(timeout: 3))
        let artist = app.links["player.artist"]
        XCTAssertTrue(artist.waitForExistence(timeout: 3))
        artist.hover()
        artist.click()
        XCTAssertTrue(artistPage.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["artist.detail.8"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["artist.detail.9"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["artist.popular.local.100"].waitForExistence(timeout: 3))

        back.click()
        XCTAssertTrue(albumPage.waitForExistence(timeout: 3))
        forward.click()
        XCTAssertTrue(artistPage.waitForExistence(timeout: 3))
        let restoredArtwork = app.buttons["player.artwork"]
        XCTAssertTrue(restoredArtwork.waitForExistence(timeout: 3))
        restoredArtwork.click()
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
    func testCommandUpAndDownAdjustVolumeWithinLimits() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--playback-clock-fixture"]
        app.launch()
        let volume = app.sliders["player.volume"]
        XCTAssertTrue(volume.waitForExistence(timeout: 3))

        func assertVolume(_ expected: Double) throws {
            let value = try XCTUnwrap(volume.value as? NSNumber)
            XCTAssertEqual(value.doubleValue, expected, accuracy: 0.001)
        }

        app.typeKey(.upArrow, modifierFlags: .command)
        try assertVolume(0.55)
        app.typeKey(.downArrow, modifierFlags: .command)
        try assertVolume(0.50)
        for _ in 0..<12 {
            app.typeKey(.upArrow, modifierFlags: .command)
        }
        try assertVolume(1)

        app.buttons["player.mute"].click()
        app.typeKey(.downArrow, modifierFlags: .command)
        try assertVolume(0)
        // Command-arrows preserve native text editing while the field has focus.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 3))
        app.typeKey(.upArrow, modifierFlags: .command)
        try assertVolume(0)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: .command)
        try assertVolume(0.05)
        XCTAssertEqual(app.buttons["player.mute"].label, "Mutar volume")
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

        volume.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).click()
        let zeroVolume = NSPredicate { _, _ in
            (volume.value as? NSNumber)?.doubleValue == 0
        }
        expectation(for: zeroVolume, evaluatedWith: volume)
        waitForExpectations(timeout: 2)
        XCTAssertEqual(mute.value as? String, "Sem volume")
        mute.click()
        XCTAssertGreaterThan((volume.value as? NSNumber)?.doubleValue ?? 0, 0)

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Volume control"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPlaylistHoverPlayStartsClickedTrackAndReplacesQueue() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture",
                                "--playback-clock-fixture", "--collection-play-fixture"]
        app.launch()
        if !app.buttons["sidebar.playlists"].isHittable { app.buttons["navigation.sidebar"].click() }
        let playlists = app.buttons["sidebar.playlists"]
        XCTAssertTrue(playlists.waitForExistence(timeout: 3))
        playlists.click()
        let playlist = app.descendants(matching: .any)["playlist.7"].firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 3))
        playlist.click()
        XCTAssertTrue(app.descendants(matching: .any)["playlist.detail.7"].waitForExistence(timeout: 3))
        let row = app.descendants(matching: .any)["playlist.track.102"].firstMatch
        if !row.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.hover()
        let play = row.buttons["track.102.positionPlay"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.click()
        let title = app.links["player.trackTitle"]
        expectation(for: NSPredicate(format: "label == %@", "Faixa de teste 3"), evaluatedWith: title)
        waitForExpectations(timeout: 3)
        XCTAssertFalse(app.staticTexts["player.error"].exists)
    }

    @MainActor
    func testArtistHoverPlayStartsClickedTrack() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture",
                                "--playback-clock-fixture", "--collection-play-fixture"]
        app.launch()
        let artist = app.links["player.artist"]
        XCTAssertTrue(artist.waitForExistence(timeout: 3))
        artist.click()
        XCTAssertTrue(app.descendants(matching: .any)["artist.detail.7"].waitForExistence(timeout: 3))
        let content = app.scrollViews["artist.detail.7"]
        XCTAssertTrue(content.waitForExistence(timeout: 3))
        content.swipeUp(velocity: .slow)
        let highlights = content.scrollViews.firstMatch
        XCTAssertTrue(highlights.waitForExistence(timeout: 3))
        highlights.swipeLeft()
        let row = app.descendants(matching: .any)["artist.popular.local.102"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Artist hover play ranking"
        capture.lifetime = .keepAlways
        add(capture)
        let play = row.buttons["track.102.positionPlay"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        play.click()
        expectation(for: NSPredicate(format: "label == %@", "Faixa de teste 3"), evaluatedWith: app.links["player.trackTitle"])
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testAlbumDoesNotHighlightTrackPlayingFromPlaylist() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture",
                                "--playback-clock-fixture", "--playlist-origin-fixture"]
        app.launch()
        let artwork = app.buttons["player.artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 3))
        artwork.click()
        XCTAssertTrue(app.descendants(matching: .any)["album.detail.42"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["album.track.100.number"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.images["album.track.100.playbackIndicator"].exists)
        XCTAssertEqual(app.links["player.trackTitle"].label, "Faixa de teste")

    }

    @MainActor
    func testOpenPlayingAlbumKeepsProgressAndAutomaticTrackChangesLive() throws {
        executionTimeAllowance = 35
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture",
                                "--playback-clock-fixture", "--album-transition-fixture"]
        app.launch()
        let artwork = app.buttons["player.artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 3))
        artwork.click()
        XCTAssertTrue(app.descendants(matching: .any)["album.detail.42"].waitForExistence(timeout: 3))
        let firstIndicator = app.images["album.track.100.playbackIndicator"]
        XCTAssertTrue(firstIndicator.waitForExistence(timeout: 3))
        let elapsed = app.staticTexts["player.elapsed"]
        let progress = app.sliders["player.progress"]
        let firstPosition = try XCTUnwrap(progress.value as? NSNumber).doubleValue
        let firstTime = elapsed.value as? String
        Thread.sleep(forTimeInterval: 2)
        XCTAssertGreaterThan(try XCTUnwrap(progress.value as? NSNumber).doubleValue, firstPosition + 0.5)
        XCTAssertNotEqual(elapsed.value as? String, firstTime)

        // Keep the album open and send no input while the first track ends.
        let nextIndicator = app.images["album.track.101.playbackIndicator"]
        XCTAssertTrue(nextIndicator.waitForExistence(timeout: 18))
        XCTAssertFalse(firstIndicator.exists)
        XCTAssertTrue(app.staticTexts["album.track.100.number"].exists)
        XCTAssertEqual(app.links["player.trackTitle"].label, "Segunda faixa de teste")
        XCTAssertEqual(app.links["player.artist"].label, "Outro artista de teste")
        let nextPosition = try XCTUnwrap(progress.value as? NSNumber).doubleValue
        Thread.sleep(forTimeInterval: 2)
        XCTAssertGreaterThan(try XCTUnwrap(progress.value as? NSNumber).doubleValue, nextPosition + 0.5)

        app.buttons["player.playPause"].click()
        let nextNumber = app.staticTexts["album.track.101.number"]
        XCTAssertTrue(nextNumber.waitForExistence(timeout: 3))
        XCTAssertFalse(nextIndicator.exists)
        let pausedPosition = try XCTUnwrap(progress.value as? NSNumber).doubleValue
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try XCTUnwrap(progress.value as? NSNumber).doubleValue, pausedPosition, accuracy: 0.01)
        app.buttons["player.playPause"].click()
        XCTAssertTrue(nextIndicator.waitForExistence(timeout: 3))
        XCTAssertFalse(nextNumber.exists)
        XCTAssertEqual(nextIndicator.label, "Em reprodução")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(try XCTUnwrap(progress.value as? NSNumber).doubleValue, pausedPosition + 0.5)
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Album after automatic track transition"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testPlaybackProgressUpdatesWithoutHoverAndStopsWhenPaused() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--playback-clock-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        let elapsed = app.staticTexts["player.elapsed"]
        let progress = app.sliders["player.progress"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 3))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.15)).hover()
        let elapsedFrame = elapsed.frame
        let progressFrame = progress.frame
        let initialPosition = try XCTUnwrap(progress.value as? NSNumber).doubleValue
        let initialTime = elapsed.value as? String
        let before = window.screenshot()
        Thread.sleep(forTimeInterval: 3)
        let after = window.screenshot()

        func crop(_ screenshot: XCUIScreenshot, to frame: CGRect) throws -> Data {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation))
            let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
            let rect = CGRect(x: (frame.minX - window.frame.minX) * scale,
                              y: (frame.minY - window.frame.minY) * scale,
                              width: frame.width * scale, height: frame.height * scale)
            let cropped = try XCTUnwrap(bitmap.cgImage?.cropping(to: rect))
            return try XCTUnwrap(NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]))
        }

        XCTAssertNotEqual(try crop(before, to: elapsedFrame), try crop(after, to: elapsedFrame),
                          "Elapsed time must repaint without mouse movement.")
        XCTAssertNotEqual(try crop(before, to: progressFrame), try crop(after, to: progressFrame),
                          "The progress fill must repaint without mouse movement.")
        XCTAssertNotEqual(elapsed.value as? String, initialTime)
        XCTAssertGreaterThan(try XCTUnwrap(progress.value as? NSNumber).doubleValue, initialPosition + 1)

        app.buttons["player.playPause"].click()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.15)).hover()
        let pausedPosition = try XCTUnwrap(progress.value as? NSNumber).doubleValue
        let pausedTime = elapsed.value as? String
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(try XCTUnwrap(progress.value as? NSNumber).doubleValue, pausedPosition, accuracy: 0.01)
        XCTAssertEqual(elapsed.value as? String, pausedTime)

        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).click()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.15)).hover()
        let seekPosition = try XCTUnwrap(progress.value as? NSNumber).doubleValue
        XCTAssertGreaterThan(seekPosition, pausedPosition + 30)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try XCTUnwrap(progress.value as? NSNumber).doubleValue, seekPosition, accuracy: 0.01)

        app.buttons["player.playPause"].click()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.15)).hover()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertGreaterThan(try XCTUnwrap(progress.value as? NSNumber).doubleValue, seekPosition + 1)
    }

    @MainActor
    func testProgressHoverKeepsPlayerLayoutStable() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let progress = app.sliders["player.progress"]
        let playPause = app.buttons["player.playPause"]
        let elapsed = app.staticTexts["player.elapsed"]
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        XCTAssertFalse(progress.isEnabled)
        XCTAssertTrue(elapsed.exists)
        XCTAssertEqual(elapsed.frame.midY, progress.frame.midY, accuracy: 1)
        XCTAssertLessThan(elapsed.frame.maxX, progress.frame.minX)

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
    func testScrollEffectAcrossLibraryAndQueue() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing", "--player-navigation-fixture", "--scroll-effect-fixture",
            "-AppleInterfaceStyle", "Dark", "-library.music.sort", "title",
            "-library.music.sortAscending", "YES", "-library.music.onlyFavorites", "NO",
            "-history.newestFirst", "NO"
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        app.buttons["sidebar.albums"].click()
        XCTAssertTrue(app.buttons["album.42"].waitForExistence(timeout: 3))
        capture("Albums at top")
        let contentPoint = window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.45))
        contentPoint.hover()
        app.buttons["album.42"].scroll(byDeltaX: 0, deltaY: -420)
        capture("Albums scrolled")
        let originalWidth = window.frame.width
        let toolbarFrame = app.toolbars.firstMatch.frame
        app.buttons["player.queue"].click()
        XCTAssertTrue(app.descendants(matching: .any)["queue.sidebar"].waitForExistence(timeout: 3))
        XCTAssertEqual(window.frame.width, originalWidth, accuracy: 2)
        XCTAssertEqual(app.toolbars.firstMatch.frame.minY, toolbarFrame.minY, accuracy: 1)
        capture("Albums scrolled with queue")
        app.buttons["player.queue"].click()
        let sidebarToggle = app.buttons["navigation.sidebar"]
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 3))
        sidebarToggle.click()
        XCTAssertFalse(app.buttons["sidebar.songs"].waitForExistence(timeout: 1))
        capture("Albums scrolled without sidebar")
        sidebarToggle.click()
        XCTAssertTrue(app.buttons["sidebar.songs"].waitForExistence(timeout: 3))

        app.buttons["sidebar.songs"].click()
        // Songs uses a native NSTableView; inspect its actual rows rather
        // than identifiers from the former SwiftUI List implementation.
        let songsTable = app.tables.firstMatch
        let firstTrack = songsTable.tableRows.element(boundBy: 0)
        let secondTrack = songsTable.tableRows.element(boundBy: 1)
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 3))
        XCTAssertTrue(secondTrack.waitForExistence(timeout: 3))
        let initialTrackFrame = firstTrack.frame
        let rowHeight = secondTrack.frame.minY - initialTrackFrame.minY
        XCTAssertGreaterThan(rowHeight, 0)
        capture("Songs at top")
        songsTable.scroll(byDeltaX: 0, deltaY: -350)
        capture("Songs scrolled")

        // Read the actual row after scrolling. Native table headers have a
        // different inset from the former SwiftUI List, so inferred title
        // rectangles do not reliably describe the covered content.
        XCTAssertLessThan(firstTrack.frame.minY, initialTrackFrame.minY)
        XCTAssertEqual(app.toolbars.firstMatch.frame.minY, toolbarFrame.minY, accuracy: 1)

        songsTable.scroll(byDeltaX: 0, deltaY: 3000)
        let restoredFirstTrack = songsTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(restoredFirstTrack.waitForExistence(timeout: 3))
        XCTAssertEqual(restoredFirstTrack.frame.minY, initialTrackFrame.minY, accuracy: 2)
        capture("Songs returned to top")

        let sidebarFrame = app.buttons["sidebar.retrospective"].frame
        app.links["player.artist"].click()
        let artistPage = app.descendants(matching: .any)["artist.detail.7"]
        XCTAssertTrue(artistPage.waitForExistence(timeout: 3))
        let artistOptions = app.descendants(matching: .any)["artist.options"]
        let artistOrganize = app.descendants(matching: .any)["artist.tracks.organize"]
        XCTAssertTrue(artistOptions.waitForExistence(timeout: 3))
        for control in [artistOptions, artistOrganize] {
            XCTAssertEqual(control.frame.width, 36, accuracy: 2)
            XCTAssertEqual(control.frame.height, 36, accuracy: 2)
            XCTAssertLessThan(control.frame.maxY, toolbarFrame.maxY + 2)
        }
        XCTAssertTrue(app.textFields["artist.tracks.search.field"].exists)
        XCTAssertLessThan(window.frame.maxX - app.buttons["player.queue"].frame.maxX, 80)
        capture("Artist detail at top")
        artistOptions.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        capture("Artist topbar hovered at top")
        contentPoint.hover()
        capture("Artist topbar after pointer leaves")
        app.buttons["player.queue"].click()
        let artistQueue = app.descendants(matching: .any)["queue.sidebar"]
        XCTAssertTrue(artistQueue.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(artistOptions.frame.maxX, artistQueue.frame.minX)
        let queueAligned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let gap = artistQueue.frame.minX - artistOptions.frame.maxX
                return gap >= 0 && gap < 40
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [queueAligned], timeout: 3), .completed)
        XCTAssertLessThan(window.frame.maxX - app.buttons["player.queue"].frame.maxX, 80)
        capture("Artist toolbar with queue")
        let artistSearchExpand = app.buttons["artist.tracks.search.expand"]
        if artistSearchExpand.exists { artistSearchExpand.click() }
        let artistSearch = app.textFields["artist.tracks.search.field"]
        XCTAssertTrue(artistSearch.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(artistOptions.frame.maxX, artistQueue.frame.minX)
        XCTAssertEqual(artistOptions.frame.width, 36, accuracy: 2)
        capture("Artist expanded search with queue")
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["player.queue"].click()
        artistPage.scroll(byDeltaX: 0, deltaY: -420)
        capture("Artist detail scrolled")
        XCTAssertEqual(app.buttons["sidebar.retrospective"].frame.minY, sidebarFrame.minY, accuracy: 1)

        app.buttons["sidebar.retrospective"].click()
        XCTAssertTrue(app.staticTexts["Faixa de teste 1 — Biblioteca para rolagem"].waitForExistence(timeout: 3))
        capture("Retrospective at top")
        app.outlines.firstMatch.scroll(byDeltaX: 0, deltaY: -420)
        capture("Retrospective scrolled")
        XCTAssertEqual(app.buttons["sidebar.retrospective"].frame.minY, sidebarFrame.minY, accuracy: 1)
    }

    private func textHighlight(in rect: CGRect, window: CGRect, bitmap: NSBitmapImageRep) throws -> Double {
        let scale = CGFloat(bitmap.pixelsWide) / window.width
        let local = rect.offsetBy(dx: -window.minX, dy: -window.minY)
        var levels: [Double] = []
        for y in Int(local.minY * scale)..<Int(local.maxY * scale) {
            for x in Int(local.minX * scale)..<Int(local.maxX * scale) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                levels.append(0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent)
            }
        }
        levels.sort()
        return levels[Int(Double(levels.count - 1) * 0.95)]
    }

    @MainActor
    func testSwitchingSidebarTabsPreservesUserWidth() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        let picker = app.descendants(matching: .any)["sidebar.sectionPicker"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        if !picker.exists {
            app.buttons["navigation.sidebar"].click()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        let originalPickerWidth = picker.frame.width
        let originalWindowWidth = window.frame.width
        XCTAssertGreaterThan(originalPickerWidth, 0)

        for section in ["playlists", "albums", "artists", "navigation"] {
            app.buttons["sidebar.section.\(section)"].click()
            XCTAssertEqual(picker.frame.width, originalPickerWidth, accuracy: 1,
                           "Changing tabs must not resize the sidebar.")
            XCTAssertEqual(window.frame.width, originalWindowWidth, accuracy: 1)
        }

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Sidebar width preserved across tabs"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSidebarControlsStayFixedOverScrollingContent() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing", "--player-navigation-fixture", "--scroll-effect-fixture",
            "-AppleInterfaceStyle", "Dark"
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        app.buttons["sidebar.section.albums"].click()
        let album = app.buttons["sidebar.album.42"]
        XCTAssertTrue(album.waitForExistence(timeout: 3))
        let picker = app.descendants(matching: .any)["sidebar.sectionPicker"]
        let search = app.buttons["sidebar.sectionSearch.toggle"]
        let pickerFrame = picker.frame
        let searchFrame = search.frame
        let albumFrame = album.frame
        let scrollView = app.scrollViews.containing(.button, identifier: "sidebar.album.42").firstMatch
        XCTAssertTrue(scrollView.exists)

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("Sidebar glass at top")
        let beforeScroll = try XCTUnwrap(NSBitmapImageRep(data: window.screenshot().pngRepresentation))
        album.scroll(byDeltaX: 0, deltaY: -110)
        XCTAssertEqual(picker.frame.minY, pickerFrame.minY, accuracy: 1)
        XCTAssertEqual(search.frame.minY, searchFrame.minY, accuracy: 1)
        XCTAssertLessThan(album.frame.minY, pickerFrame.minY)
        capture("Sidebar content behind glass")
        let afterScroll = try XCTUnwrap(NSBitmapImageRep(data: window.screenshot().pngRepresentation))
        // Accessibility reports the inset viewport, so check pixels above it:
        // artwork scrolling behind the controls must change the native backdrop.
        let backdrop = CGRect(x: albumFrame.minX + 10, y: pickerFrame.maxY + 4,
                              width: 30, height: 6)
        let beforeLevel = try textHighlight(in: backdrop, window: window.frame, bitmap: beforeScroll)
        let afterLevel = try textHighlight(in: backdrop, window: window.frame, bitmap: afterScroll)
        XCTAssertGreaterThan(abs(afterLevel - beforeLevel), 0.003,
                             "Scrolling content must remain visible behind the fixed area.")

        search.click()
        let field = app.textFields["sidebar.sectionSearch.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("120")
        XCTAssertTrue(app.buttons["sidebar.album.161"].waitForExistence(timeout: 3))
        capture("Sidebar glass search expanded")

        for section in ["artists", "playlists", "navigation"] {
            app.buttons["sidebar.section.\(section)"].click()
            XCTAssertEqual(picker.frame.minY, pickerFrame.minY, accuracy: 1)
            if section != "navigation" {
                XCTAssertTrue(app.buttons["sidebar.sectionSearch.toggle"].exists)
            }
        }
        XCTAssertTrue(app.buttons["sidebar.songs"].isHittable)
    }

    @MainActor
    func testNavigationShellControlsExist() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let sectionPicker = app.descendants(matching: .any)["sidebar.sectionPicker"]
        XCTAssertTrue(sectionPicker.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["sidebar.search.open"].exists)
        XCTAssertTrue(app.buttons["navigation.back"].exists)
        XCTAssertTrue(app.buttons["navigation.forward"].exists)
    }

    @MainActor
    func testCommandBracketsFollowAvailableNavigationHistory() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let home = app.descendants(matching: .any)["home.page"]
        let album = app.descendants(matching: .any)["album.detail.42"]
        let back = app.buttons["navigation.back"]
        let forward = app.buttons["navigation.forward"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertFalse(back.isEnabled)
        XCTAssertFalse(forward.isEnabled)
        app.typeKey("[", modifierFlags: .command)
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(home.exists)

        app.buttons["player.artwork"].click()
        XCTAssertTrue(album.waitForExistence(timeout: 3))
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertFalse(back.isEnabled)
        XCTAssertTrue(forward.isEnabled)
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(album.waitForExistence(timeout: 3))
        XCTAssertFalse(forward.isEnabled)

        // Explicit history shortcuts work while search is focused; Command-arrows remain editing keys.
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        app.typeText("teste")
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(album.waitForExistence(timeout: 3))
        XCTAssertTrue(forward.isEnabled)

        app.buttons["sidebar.home"].click()
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertFalse(forward.isEnabled)
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(home.exists)
        XCTAssertTrue(field.exists)
    }

    @MainActor
    func testHomeSearchDoesNotAutofocusOnLaunchOrReturnButCommandKFocuses() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, false)
        XCTAssertFalse(app.descendants(matching: .any)["search.preview"].exists)
        app.typeKey("k", modifierFlags: .command)
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        waitForExpectations(timeout: 3)
        if !app.buttons["sidebar.albums"].isHittable { app.buttons["navigation.sidebar"].click() }
        app.buttons["sidebar.albums"].click()
        XCTAssertFalse(field.exists)
        app.buttons["sidebar.home"].click()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, false)
        XCTAssertFalse(app.descendants(matching: .any)["search.preview"].exists)
        app.typeKey("k", modifierFlags: .command)
        expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testCommandKOpensHomeAndRefocusesWithSidebarHidden() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let albumsTab = app.buttons["sidebar.section.albums"]
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 3))
        albumsTab.click()

        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: field)
        waitForExpectations(timeout: 3)
        app.typeText("__atalho_pesquisa__")
        XCTAssertEqual(field.value as? String, "__atalho_pesquisa__")

        let sidebarToggle = app.buttons["navigation.sidebar"]
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 3))
        sidebarToggle.click()
        XCTAssertFalse(albumsTab.waitForExistence(timeout: 1))
        app.typeKey("k", modifierFlags: .command)
        expectation(for: focused, evaluatedWith: field)
        waitForExpectations(timeout: 3)
        app.typeKey("a", modifierFlags: .command)
        app.typeText("digitavel")
        XCTAssertEqual(field.value as? String, "digitavel")
    }

    @MainActor
    func testHomeSearchHistoryOpensResultsOnClickAndPersistsAcrossLaunches() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let home = app.descendants(matching: .any)["home.page"]
        let results = app.descendants(matching: .any)["search.page"]
        let term = "__historico_home__"
        let recentID = "search.preview.recent:\(term)"
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue(home.exists)
        app.typeKey("a", modifierFlags: .command)
        field.typeText(term)
        XCTAssertTrue(home.exists)
        XCTAssertFalse(results.exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertFalse(home.exists)
        let summary = app.descendants(matching: .any)["search.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        let navigation = app.descendants(matching: .any)["navigation.history"]
        XCTAssertEqual(summary.frame.minX - navigation.frame.maxX, 12, accuracy: 1)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "0 artistas, 0 álbuns, 0 músicas, 0 playlists"),
                    evaluatedWith: summary)
        waitForExpectations(timeout: 3)
        let resultsCapture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        resultsCapture.name = "Dedicated search results toolbar metadata"
        resultsCapture.lifetime = .keepAlways
        add(resultsCapture)

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertFalse(summary.exists)
        let recent = app.buttons[recentID]
        XCTAssertTrue(recent.waitForExistence(timeout: 3))
        recent.click()
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, term)

        app.terminate()
        app.launch()
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.buttons[recentID].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Pesquisas recentes"].exists)
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Home search with recent queries"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons[recentID].click()
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, term)
    }

    @MainActor
    func testDedicatedResultsToolbarShowsExecutedQueryAndCounts() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("__metadata_resultados__")
        let summary = app.descendants(matching: .any)["search.summary"]
        XCTAssertFalse(summary.exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        expectation(for: NSPredicate(format: "value CONTAINS %@", "0 artistas, 0 álbuns, 0 músicas, 0 playlists"),
                    evaluatedWith: summary)
        waitForExpectations(timeout: 3)
        XCTAssertTrue((summary.value as? String)?.contains("__metadata_resultados__") == true,
                      "Metadata: \(String(describing: summary.value)); field: \(String(describing: field.value))")
        let navigation = app.descendants(matching: .any)["navigation.history"]
        XCTAssertEqual(summary.frame.minX - navigation.frame.maxX, 12, accuracy: 1)
        XCTAssertFalse(summary.frame.intersects(field.frame))
        app.typeKey("a", modifierFlags: .command)
        field.typeText("outro termo ainda não enviado")
        XCTAssertTrue((summary.value as? String)?.contains("__metadata_resultados__") == true)
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Dedicated results toolbar with submitted metadata"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testSearchWaitsForEnterAndHasNoPreviewForMissingResults() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["player.queue"].waitForExistence(timeout: 3))
        app.buttons["player.queue"].click()
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("__previa_pesquisa_inexistente__")
        XCTAssertFalse(app.descendants(matching: .any)["search.section.artists"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["search.preview"].waitForExistence(timeout: 2))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Nenhum artista encontrado para esta pesquisa."].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true)
        app.typeKey("a", modifierFlags: .command)
        app.typeText("__outra_pesquisa__")
        XCTAssertTrue(app.staticTexts["Nenhum artista encontrado para esta pesquisa."].exists)
        XCTAssertFalse(app.descendants(matching: .any)["search.preview"].exists)
    }

    @MainActor
    func testGlobalSearchCanBeClickedWithQueueOpenAfterLosingFocus() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("__pesquisa_clique__")

        app.buttons["player.queue"].click()
        for _ in 0..<2 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.7)).click()
            XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, false)
            // A coordinate click exercises native hit testing, without requesting focus.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true)
            app.typeKey("a", modifierFlags: .command)
            app.typeText("__pesquisa_com_fila__")
            XCTAssertEqual(field.value as? String, "__pesquisa_com_fila__")
        }
    }

    @MainActor
    func testHomeSearchShortcutFocusesToolbarAndEnterOpensResults() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["home.page"].waitForExistence(timeout: 3))

        let searchField = app.descendants(matching: .any)["search.field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        XCTAssertEqual(
            searchField.value(forKey: "hasKeyboardFocus") as? Bool,
            true
        )

        let initialFieldFrame = searchField.frame
        let longQuery = String(repeating: "__durvald_resultado_inexistente__ ", count: 4)
        searchField.typeText(longQuery)
        XCTAssertEqual(searchField.value as? String, longQuery)
        XCTAssertEqual(searchField.frame.height, initialFieldFrame.height, accuracy: 1)
        XCTAssertEqual(searchField.frame.width, initialFieldFrame.width, accuracy: 1)
        app.typeKey(.return, modifierFlags: [])
        for message in [
            "Nenhum artista encontrado para esta pesquisa.",
            "Nenhum álbum encontrado para esta pesquisa.",
            "Nenhuma faixa encontrada para esta pesquisa.",
            "Nenhuma playlist encontrada para esta pesquisa."
        ] {
            XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 3))
        }

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
    func testAppLaunchesOnHomeWithSearchAndNoSearchSidebarEntry() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let homePage = app.descendants(matching: .any)["home.page"]
        let searchButton = app.buttons["sidebar.search.open"]
        let homeButton = app.buttons["sidebar.home"]

        XCTAssertTrue(homePage.waitForExistence(timeout: 3))
        XCTAssertFalse(searchButton.exists)
        XCTAssertTrue(homeButton.waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["search.field"].exists)
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
    func testRetrospectivePlaylistPreviewStaysUnsavedAndOffersLiveOrSnapshot() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--scroll-effect-fixture", "--retrospective-date-fixture"]
        app.launch()
        let retrospective = app.buttons["sidebar.retrospective"]
        if !retrospective.isHittable { app.buttons["navigation.sidebar"].click() }
        XCTAssertTrue(retrospective.waitForExistence(timeout: 3))
        retrospective.click()
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Fill"].click()
        let options = app.descendants(matching: .any)["retrospective.viewOptions"]
        options.click()
        app.menuItems["Diário"].click()
        let banner = app.buttons["retrospective.playlist.banner"]
        let scroll = app.scrollViews.containing(.any, identifier: "retrospective.overview.header").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        for _ in 0..<20 where !banner.isHittable {
            let distance = scroll.frame.midY - banner.frame.midY
            scroll.scroll(byDeltaX: 0, deltaY: max(-300, min(300, distance)))
        }
        if !banner.isHittable {
            let diagnostic = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            diagnostic.name = "Replay banner scroll diagnostic"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
        }
        XCTAssertTrue(banner.isHittable)
        let playlists = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.playlist."))
        let originalCount = playlists.count
        let bannerCapture = XCTAttachment(screenshot: banner.screenshot())
        bannerCapture.name = "Replay generated banner"
        bannerCapture.lifetime = .keepAlways
        add(bannerCapture)
        banner.click()
        XCTAssertTrue(app.scrollViews["retrospective.playlist.preview"].waitForExistence(timeout: 3))
        let summary = app.descendants(matching: .any)["retrospective.playlist.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        let countReady = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "10 músicas", "10 músicas"), object: summary)
        XCTAssertEqual(XCTWaiter.wait(for: [countReady], timeout: 5), .completed)
        XCTAssertEqual(playlists.count, originalCount)
        XCTAssertFalse(app.buttons["retrospective.playlist.options"].exists)
        XCTAssertFalse(app.steppers["retrospective.playlist.size"].exists)
        let replayRow = app.descendants(matching: .any)["retrospective.playlist.track.100"].firstMatch
        XCTAssertTrue(replayRow.waitForExistence(timeout: 3))
        replayRow.hover()
        let replayRating = replayRow.descendants(matching: .any)["collection.track.100.rating"].firstMatch
        let replayDuration = replayRow.staticTexts["collection.track.100.duration"]
        let replayOptions = replayRow.descendants(matching: .any)["collection.track.100.options"].firstMatch
        XCTAssertTrue(replayRating.waitForExistence(timeout: 3))
        XCTAssertLessThan(replayRating.frame.maxX, replayDuration.frame.minX)
        XCTAssertLessThan(replayDuration.frame.maxX, replayOptions.frame.minX)
        XCTAssertFalse(replayRow.buttons["Adicionar Faixa de teste 1 — Biblioteca para rolagem à fila"].exists)
        let play = app.buttons["retrospective.playlist.play"]
        let save = app.buttons["retrospective.playlist.save"]
        XCTAssertGreaterThan(save.frame.minX, play.frame.maxX)
        XCTAssertEqual(save.frame.midY, play.frame.midY, accuracy: 1)
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(app.buttons["Manter atualizada"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Salvar como está"].exists)
        app.sheets.buttons["Cancelar"].click()
        XCTAssertEqual(playlists.count, originalCount)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Unsaved retrospective playlist preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["navigation.back"].click()
        XCTAssertTrue(app.descendants(matching: .any)["retrospective.viewOptions"].waitForExistence(timeout: 3))
        let selector = app.popUpButtons["retrospective.dateScope"]
        selector.click()
        app.menuItems["Fevereiro de 2024"].click()
        let historicalSummary = app.descendants(matching: .any)["retrospective.summary"]
        let historyReady = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "1 reprodução", "1 reprodução"), object: historicalSummary)
        XCTAssertEqual(XCTWaiter.wait(for: [historyReady], timeout: 5), .completed)
        XCTAssertFalse(banner.exists, "A period below its minimum must not offer a playlist")
        XCTAssertEqual(playlists.count, originalCount)
    }

    @MainActor
    func testRetrospectiveCalendarSelectorFiltersHistoricalMonthsAndYears() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--scroll-effect-fixture",
                                "--retrospective-date-fixture"]
        app.launch()
        let retrospective = app.buttons["sidebar.retrospective"]
        if !retrospective.isHittable { app.buttons["navigation.sidebar"].click() }
        XCTAssertTrue(retrospective.waitForExistence(timeout: 3))
        retrospective.click()
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Fill"].click()
        let options = app.descendants(matching: .any)["retrospective.viewOptions"]
        let selector = app.popUpButtons["retrospective.dateScope"]
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "retrospective.date."))
        for period in ["Diário", "Semanal", "Mensal"] {
            options.click()
            app.menuItems[period].click()
            XCTAssertTrue(selector.waitForExistence(timeout: 3))
            selector.click()
            let choice = period == "Mensal" ? "2024" : "Fevereiro de 2024"
            XCTAssertTrue(app.menuItems[choice].waitForExistence(timeout: 3))
            XCTAssertFalse(app.menuItems["2023"].exists)
            XCTAssertFalse(app.menuItems["Janeiro de 2024"].exists)
            app.menuItems[choice].click()
            XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 3))
            if period == "Diário" {
                XCTAssertEqual(tabs.firstMatch.label, "29")
                XCTAssertEqual(tabs.count, 29)
            } else if period == "Semanal" {
                XCTAssertTrue(tabs.firstMatch.label.hasPrefix("25 - 02") || tabs.firstMatch.label.hasPrefix("26 - 03"))
            } else {
                tabs.matching(NSPredicate(format: "label == %@", "Fevereiro")).firstMatch.click()
            }
            let summary = app.descendants(matching: .any)["retrospective.summary"]
            XCTAssertTrue(summary.waitForExistence(timeout: 3))
            XCTAssertTrue((summary.value as? String ?? "").contains("1 reprodução"))
            let frame = selector.frame
            let scroll = app.scrollViews.containing(.button, identifier: tabs.firstMatch.identifier).firstMatch
            scroll.swipeLeft()
            XCTAssertEqual(selector.frame.minX, frame.minX, accuracy: 1)
            XCTAssertEqual(selector.frame.width, frame.width, accuracy: 1)
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = "Retrospective calendar selector — \(period)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        options.click()
        app.menuItems["Anual"].click()
        XCTAssertFalse(selector.waitForExistence(timeout: 1))
    }

    @MainActor
    func testRetrospectiveTabsKeepWindowAndToolbarGeometry() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--scroll-effect-fixture"]
        app.launch()
        let retrospective = app.buttons["sidebar.retrospective"]
        if !retrospective.isHittable { app.buttons["navigation.sidebar"].click() }
        XCTAssertTrue(retrospective.waitForExistence(timeout: 3))
        retrospective.click()
        let options = app.descendants(matching: .any)["retrospective.viewOptions"]
        options.click()
        app.menuItems["Mensal"].click()
        let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "retrospective.date."))
        XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 3))
        let window = app.windows.firstMatch
        let originalWindow = window.frame
        let originalToolbar = app.toolbars.firstMatch.frame
        let visible = tabs.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertGreaterThan(visible.count, 1)
        guard let first = visible.first else { return }
        let originalPicker = first.frame
        for button in visible.prefix(3) {
            button.click()
            XCTAssertTrue(button.isSelected)
            XCTAssertEqual(window.frame.width, originalWindow.width, accuracy: 1)
            XCTAssertEqual(window.frame.height, originalWindow.height, accuracy: 1)
            XCTAssertEqual(app.toolbars.firstMatch.frame.height, originalToolbar.height, accuracy: 1)
            XCTAssertEqual(button.frame.minY, originalPicker.minY, accuracy: 1)
            XCTAssertEqual(button.frame.height, originalPicker.height, accuracy: 1)
        }
    }

    @MainActor
    func testRetrospectivePeriodMenuRestoresSelectionAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--scroll-effect-fixture"]
        app.launch()
        func openRetrospective() {
            let button = app.buttons["sidebar.retrospective"]
            if !button.isHittable { app.buttons["navigation.sidebar"].click() }
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.click()
        }
        func select(_ title: String) {
            let options = app.descendants(matching: .any)["retrospective.viewOptions"]
            XCTAssertTrue(options.waitForExistence(timeout: 3))
            options.click()
            for label in ["Diário", "Semanal", "Mensal", "Anual"] {
                XCTAssertTrue(app.menuItems[label].exists)
            }
            app.menuItems[title].click()
        }
        openRetrospective()
        for title in ["Diário", "Semanal", "Anual", "Mensal"] {
            select(title)
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND value == %@", "retrospective.overview.header", title)).firstMatch.waitForExistence(timeout: 5))
        }
        app.terminate()
        app.launch()
        openRetrospective()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND value == %@", "retrospective.overview.header", "Mensal")).firstMatch.waitForExistence(timeout: 5))
        select("Semanal")
    }

    func testRetrospectiveToolbarSearchFiltersOlderEntriesAndUpdatesSummary() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--scroll-effect-fixture"]
        app.launch()
        let retrospectiveTab = app.buttons["sidebar.retrospective"]
        if !retrospectiveTab.isHittable { app.buttons["navigation.sidebar"].click() }
        XCTAssertTrue(retrospectiveTab.waitForExistence(timeout: 3))
        retrospectiveTab.click()
        let search = app.textFields["retrospective.search.field"]
        if !search.exists { app.buttons["retrospective.search.expand"].click() }
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("Faixa de teste 240")
        XCTAssertTrue(app.descendants(matching: .any)["retrospective.entry.240"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["retrospective.entry.1"].exists)
        let summary = app.descendants(matching: .any)["retrospective.summary"]
        // Compact focused search intentionally hides the metadata. Check it
        // after leaving the field, following the shared toolbar behavior.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        XCTAssertTrue((summary.value as? String ?? "").contains("1 reprodução"))
        let options = app.descendants(matching: .any)["retrospective.viewOptions"]
        XCTAssertGreaterThanOrEqual(options.frame.width, 30)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Retrospective shared toolbar with filtered metadata"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPlaylistsTopbarShowsSummarySearchAndCreationMenu() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Fill"].click()
        if !app.buttons["sidebar.playlists"].isHittable { app.buttons["navigation.sidebar"].click() }
        app.buttons["sidebar.playlists"].click()
        let summary = app.descendants(matching: .any)["playlists.summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 3))
        let navigation = app.descendants(matching: .any)["navigation.history"]
        XCTAssertEqual(summary.frame.minX - navigation.frame.maxX, 12, accuracy: 1)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "0 playlists, 0 músicas"), evaluatedWith: summary)
        waitForExpectations(timeout: 3)
        XCTAssertFalse(app.buttons["Nova smart playlist"].exists)
        XCTAssertFalse(app.buttons["Importar playlist"].exists)

        let addMenu = app.descendants(matching: .any)["playlists.add"].firstMatch
        let options = app.descendants(matching: .any)["playlists.listingMode"].firstMatch
        let toggle = app.buttons["player.queue"]
        for queueOpen in [false, true] {
            if queueOpen { toggle.click() }
            let expand = app.buttons["playlists.search.expand"]
            if expand.exists { expand.click() }
            let field = app.textFields["playlists.search.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            XCTAssertTrue(addMenu.isHittable)
            XCTAssertLessThan(addMenu.frame.maxX, field.frame.minX)
            XCTAssertEqual(window.frame.maxX - toggle.frame.maxX, 8, accuracy: 1)
            let edge = queueOpen ? app.descendants(matching: .any)["queue.sidebar"].frame.minX : toggle.frame.minX
            XCTAssertEqual(edge - options.frame.maxX, 8, accuracy: 1)
            field.click()
            field.typeText("teste")
            XCTAssertEqual(field.value as? String, "teste")
            XCTAssertTrue(app.staticTexts["Nenhuma playlist encontrada"].waitForExistence(timeout: 3))
            expectation(for: NSPredicate(format: "value CONTAINS %@", "Resultados para “teste” • 0 playlists, 0 músicas"),
                        evaluatedWith: summary)
            waitForExpectations(timeout: 3)
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
            app.typeKey(.escape, modifierFlags: [])
        }
        toggle.click()
        for action in ["Nova playlist", "Nova playlist inteligente", "Importar playlist"] {
            addMenu.click()
            for title in ["Nova playlist", "Nova playlist inteligente", "Importar playlist"] {
                XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: 3))
            }
            app.menuItems[action].click()
            if action == "Nova playlist" {
                XCTAssertTrue(app.textFields["playlist.new.title"].waitForExistence(timeout: 3))
                app.buttons["Cancelar"].click()
            } else if action == "Nova playlist inteligente" {
                XCTAssertTrue(app.buttons["Adicionar regra"].waitForExistence(timeout: 3))
                app.buttons["Cancelar"].click()
            } else {
                let panel = app.sheets["open-panel"]
                XCTAssertTrue(panel.waitForExistence(timeout: 3))
                let cancel = app.buttons["CancelButton"]
                XCTAssertTrue(cancel.waitForExistence(timeout: 3))
                cancel.click()
            }
        }
        let capture = XCTAttachment(screenshot: window.screenshot())
        capture.name = "Playlists shared topbar"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testAlbumUsesSharedTopbarAndCircularHeaderActions() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Fill"].click()
        app.links["player.trackTitle"].click()
        XCTAssertTrue(app.descendants(matching: .any)["album.detail.42"].waitForExistence(timeout: 3))

        let artwork = app.descendants(matching: .any)["album.header.artwork"].firstMatch
        let play = app.buttons["collection.play"]
        let shuffle = app.buttons["collection.shuffle"]
        let favorite = app.buttons["collection.favorite"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        XCTAssertEqual(play.frame.width, 60, accuracy: 1)
        for button in [shuffle, favorite] {
            XCTAssertEqual(button.frame.width, 40, accuracy: 1)
            XCTAssertEqual(button.frame.height, 40, accuracy: 1)
            XCTAssertEqual(button.frame.midY, play.frame.midY, accuracy: 1)
        }
        XCTAssertTrue(artwork.exists)
        XCTAssertGreaterThan(play.frame.minX, artwork.frame.maxX)
        XCTAssertEqual(shuffle.frame.minX - play.frame.maxX, 16, accuracy: 1)
        XCTAssertEqual(favorite.frame.minX - shuffle.frame.maxX, 16, accuracy: 1)

        let toggle = app.buttons["player.queue"]
        let organize = app.descendants(matching: .any)["album.tracks.organize"].firstMatch
        let options = app.descendants(matching: .any)["album.options"].firstMatch
        for queueOpen in [false, true] {
            if queueOpen { toggle.click() }
            XCTAssertTrue(organize.waitForExistence(timeout: 3))
            XCTAssertTrue(options.isHittable)
            XCTAssertEqual(window.frame.maxX - toggle.frame.maxX, 8, accuracy: 1)
            let edge = queueOpen ? app.descendants(matching: .any)["queue.sidebar"].frame.minX : toggle.frame.minX
            XCTAssertEqual(edge - organize.frame.maxX, 8, accuracy: 1)
            XCTAssertEqual(organize.frame.minX - options.frame.maxX, 8, accuracy: 1)
            let expand = app.buttons["album.tracks.search.expand"]
            if expand.exists { expand.click() }
            let field = app.textFields["album.tracks.search.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.click()
            field.typeText("sem correspondencia")
            XCTAssertEqual(field.value as? String, "sem correspondencia")
            XCTAssertFalse(app.staticTexts["album.track.100.number"].exists)
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
            XCTAssertTrue(app.staticTexts["album.track.100.number"].waitForExistence(timeout: 3))
            app.typeKey(.escape, modifierFlags: [])
        }
        toggle.click()
        organize.click()
        XCTAssertTrue(app.menuItems["Título"].waitForExistence(timeout: 3))
        app.menuItems["Título"].click()
        let capture = XCTAttachment(screenshot: window.screenshot())
        capture.name = "Album shared topbar and circular header actions"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testArtistHeaderActionsMatchReferenceAndKeepToggleStateSeparate() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Fill"].click()
        app.links["player.artist"].rightClick()
        app.menuItems["Abrir artista"].click()

        let ids = ["artist.follow", "artist.identity.badge", "collection.play",
                   "collection.shuffle", "artist.favorite"]
        let buttons = ids.map { app.buttons[$0] }
        for (index, button) in buttons.enumerated() {
            XCTAssertTrue(button.waitForExistence(timeout: 3), ids[index])
            let size: CGFloat = index == 2 ? 72 : 48
            XCTAssertEqual(button.frame.width, size, accuracy: 1, ids[index])
            XCTAssertEqual(button.frame.height, size, accuracy: 1, ids[index])
            XCTAssertEqual(button.frame.midY, buttons[2].frame.midY, accuracy: 1, ids[index])
            if index > 0 { XCTAssertGreaterThan(button.frame.minX, buttons[index - 1].frame.maxX) }
        }
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Artist centered circular header actions"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        for (id, inactive, active) in [("artist.follow", "Não seguindo", "Seguindo"),
                                       ("artist.favorite", "Não favorito", "Favorito")] {
            let button = app.buttons[id]
            let initial = button.value as? String
            XCTAssertTrue(initial == inactive || initial == active)
            button.click()
            expectation(for: NSPredicate(format: "value == %@", initial == inactive ? active : inactive),
                        evaluatedWith: button)
            waitForExpectations(timeout: 3)
            button.click()
            expectation(for: NSPredicate(format: "value == %@", initial ?? inactive), evaluatedWith: button)
            waitForExpectations(timeout: 3)
        }

        let play = app.buttons["collection.play"]
        let shuffle = app.buttons["collection.shuffle"]
        // The navigation fixture has no audio core. These controls still keep
        // momentary presentation; only follow and favorite retain selection.
        shuffle.click()
        XCTAssertFalse(shuffle.isSelected)
        play.click()
        XCTAssertFalse(play.isSelected)
        XCTAssertEqual(play.label, "Reproduzir")
    }

    @MainActor
    func testArtistToolbarWorksWhenOpenedDirectlyAndPanelsToggle() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Fill"].click()
        if !app.buttons["sidebar.songs"].exists {
            app.buttons["navigation.sidebar"].click()
        }
        XCTAssertTrue(app.buttons["sidebar.songs"].waitForExistence(timeout: 3))
        app.links["player.artist"].rightClick()
        app.menuItems["Abrir artista"].click()
        XCTAssertTrue(app.descendants(matching: .any)["artist.detail.7"].waitForExistence(timeout: 3))

        let queueToggle = app.buttons["player.queue"]
        let options = app.descendants(matching: .any)["artist.options"]
        for queueOpen in [false, true] {
            if queueOpen {
                queueToggle.click()
                XCTAssertTrue(app.descendants(matching: .any)["queue.sidebar"].waitForExistence(timeout: 3))
            }
            var sidebarClosed = false
            for closeSidebar in [false, true, false] {
                if closeSidebar != sidebarClosed {
                    app.activate()
                    app.buttons["navigation.sidebar"].click()
                    sidebarClosed = closeSidebar
                    let visible = NSPredicate(format: "exists == %@", NSNumber(value: !closeSidebar))
                    expectation(for: visible, evaluatedWith: app.buttons["sidebar.songs"])
                    waitForExpectations(timeout: 3)
                }
                XCTAssertTrue(options.waitForExistence(timeout: 3))
                XCTAssertTrue(options.isHittable)
                XCTAssertTrue(queueToggle.isHittable)
                XCTAssertEqual(window.frame.maxX - queueToggle.frame.maxX, 8, accuracy: 1)
                let optionsEdge = queueOpen ? app.descendants(matching: .any)["queue.sidebar"].frame.minX
                    : queueToggle.frame.minX
                XCTAssertEqual(optionsEdge - options.frame.maxX, 8, accuracy: 1)
                let expand = app.buttons["artist.tracks.search.expand"]
                if expand.exists { expand.click() }
                let field = app.textFields["artist.tracks.search.field"]
                XCTAssertTrue(field.waitForExistence(timeout: 3))
                XCTAssertTrue(field.isHittable)
                field.click()
                field.typeText("teste")
                XCTAssertEqual(field.value as? String, "teste")
                XCTAssertTrue(NSPredicate(format: "hasKeyboardFocus == true").evaluate(with: field))
                XCTAssertTrue(queueToggle.isHittable)
                app.typeKey("a", modifierFlags: .command)
                app.typeKey(.delete, modifierFlags: [])
                app.typeKey(.escape, modifierFlags: [])
            }
            if queueOpen { queueToggle.click() }
        }
    }

    @MainActor
    func testToolbarSummaryKeepsTwelvePointNavigationGap() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        for (destination, summaryID) in [("songs", "library.summary"), ("albums", "albums.summary"),
                                         ("artists", "artists.summary"), ("retrospective", "retrospective.summary"),
                                         ("playlists", "playlists.summary")] {
            let tab = app.buttons["sidebar.\(destination)"]
            if !tab.isHittable { app.buttons["navigation.sidebar"].click() }
            tab.click()
            let summary = app.descendants(matching: .any)[summaryID]
            XCTAssertTrue(summary.waitForExistence(timeout: 3))
            let toggle = app.buttons["player.queue"]
            for queueOpen in [false, true] {
                if queueOpen { toggle.click() }
                var sidebarClosed = false
                for closeSidebar in [false, true, false] {
                    if closeSidebar != sidebarClosed {
                        app.buttons["navigation.sidebar"].click()
                        sidebarClosed = closeSidebar
                    }
                    let navigation = app.descendants(matching: .any)["navigation.history"]
                    XCTAssertEqual(summary.frame.minX - navigation.frame.maxX, 12, accuracy: 1,
                                   "\(destination), queue: \(queueOpen), sidebar closed: \(closeSidebar)")
                    XCTAssertEqual(window.frame.maxX - toggle.frame.maxX, 8, accuracy: 1, destination)
                }
                if queueOpen { toggle.click() }
            }
        }
    }

    @MainActor
    func testToolbarSpacingStaysStableAcrossPageNavigation() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let toggle = app.buttons["player.queue"]
        let optionsIDs = ["songs": "library.viewOptions", "albums": "albums.listingMode",
                          "artists": "artists.listingMode", "playlists": "playlists.listingMode",
                          "retrospective": "retrospective.viewOptions"]
        let destinations = ["home", "home", "retrospective", "artists", "home",
                            "home", "artists", "albums", "songs", "playlists", "retrospective"]
        for queueOpen in [false, true] {
            if queueOpen { toggle.click() }
            for destination in destinations {
                let tab = app.buttons["sidebar.\(destination)"]
                if !tab.isHittable { app.buttons["navigation.sidebar"].click() }
                XCTAssertTrue(tab.waitForExistence(timeout: 3))
                tab.click()
                XCTAssertTrue(toggle.isHittable)
                if abs(window.frame.maxX - toggle.frame.maxX - 8) > 1 {
                    let attachment = XCTAttachment(screenshot: window.screenshot())
                    attachment.name = "Toolbar spacing after \(destination)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                XCTAssertEqual(window.frame.maxX - toggle.frame.maxX, 8, accuracy: 1, destination)
                if let identifier = optionsIDs[destination] {
                    let options = app.descendants(matching: .any)[identifier]
                    XCTAssertTrue(options.waitForExistence(timeout: 3))
                    XCTAssertTrue(options.isHittable)
                    let edge = queueOpen ? app.descendants(matching: .any)["queue.sidebar"].frame.minX
                        : toggle.frame.minX
                    XCTAssertEqual(edge - options.frame.maxX, 8, accuracy: 1,
                                   "\(destination), queue open: \(queueOpen)")
                }
            }
            if queueOpen { toggle.click() }
        }
    }

    @MainActor
    func testQueueToggleKeepsEightPointTrailingInsetAcrossPages() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        if window.frame.width < 700 {
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Fill"].click()
        }
        let toggle = app.buttons["player.queue"]
        for destination in ["home", "home", "songs", "albums", "artists", "playlists", "retrospective"] {
            let tab = app.buttons["sidebar.\(destination)"]
            if !tab.isHittable { app.buttons["navigation.sidebar"].click() }
            XCTAssertTrue(tab.waitForExistence(timeout: 3))
            tab.click()
            for queueOpen in [false, true] {
                if queueOpen { toggle.click() }
                XCTAssertTrue(toggle.isHittable)
                let inset = window.frame.maxX - toggle.frame.maxX
                XCTAssertEqual(inset, 8, accuracy: 1, "\(destination), queue open: \(queueOpen)")
                if queueOpen { toggle.click() }
            }
        }
    }

    @MainActor
    func testLibraryToolbarKeepsSizeAndSearchFocusAcrossNativeWindowResizes() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        for (destination, search, optionsID) in [
            ("songs", "library", "library.viewOptions"),
            ("albums", "albums", "albums.listingMode"),
            ("artists", "artists", "artists.listingMode"),
            ("retrospective", "retrospective", "retrospective.viewOptions"),
            ("genres", "classification", "classification.order"),
        ] {
            let windowMenu = app.menuBars.menuBarItems["Window"]
            windowMenu.click()
            app.menuItems["Fill"].click()
            let tab = app.buttons["sidebar.\(destination)"]
            if !tab.isHittable { app.buttons["navigation.sidebar"].click() }
            XCTAssertTrue(tab.waitForExistence(timeout: 3))
            tab.click()

            // Cover the unfocused transition too: the search collapses next
            // to the metadata, whose typography must keep its normal height.
            windowMenu.click()
            app.menuItems["Move & Resize"].click()
            app.menuItems["Left"].click()
            let visibleSummary = app.descendants(matching: .any)["\(search).summary"]
            XCTAssertTrue(visibleSummary.waitForExistence(timeout: 3))
            XCTAssertGreaterThanOrEqual(visibleSummary.frame.height, 26)
            let compactOptions = app.descendants(matching: .any)[optionsID]
            XCTAssertGreaterThanOrEqual(compactOptions.frame.height, 30)
            XCTAssertGreaterThanOrEqual(compactOptions.frame.width, 30)
            let compactSearch = app.buttons["\(search).search.expand"]
            if compactSearch.exists {
                XCTAssertGreaterThanOrEqual(compactSearch.frame.height, 30)
                XCTAssertFalse(visibleSummary.frame.intersects(compactSearch.frame))
            }
            windowMenu.click()
            app.menuItems["Fill"].click()

            let initialWidth = window.frame.width
            let field = app.textFields["\(search).search.field"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.click()
            field.typeText("teste")

            // Window-manager actions change the actual window bounds. Synthetic
            // edge drags can be ignored by the macOS UI-test event dispatcher.
            windowMenu.click()
            app.menuItems["Move & Resize"].click()
            app.menuItems["Left"].click()
            XCTAssertGreaterThan(abs(window.frame.width - initialWidth), 40)
            XCTAssertTrue(field.exists)
            XCTAssertEqual(field.value as? String, "teste")
            XCTAssertTrue(NSPredicate(format: "hasKeyboardFocus == true").evaluate(with: field))
            XCTAssertGreaterThanOrEqual(field.frame.height, 14)
            let options = app.descendants(matching: .any)[optionsID]
            XCTAssertGreaterThanOrEqual(options.frame.height, 30)
            XCTAssertGreaterThanOrEqual(options.frame.width, 30)
            let summary = app.descendants(matching: .any)["\(search).summary"]
            if summary.exists {
                XCTAssertFalse(summary.frame.intersects(field.frame),
                    "Focused search must reserve space instead of overlapping the summary.")
            }

            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "\(destination) focused search after native resize"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    @MainActor
    func testLibraryToolbarKeepsControlSizesWhenPanelsToggle() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        let destinations = [
            ("songs", "library", "library.viewOptions"),
            ("albums", "albums", "albums.listingMode"),
            ("artists", "artists", "artists.listingMode"),
            ("retrospective", "retrospective", "retrospective.viewOptions"),
            ("genres", "classification", "classification.order"),
        ]
        for (destination, search, optionsID) in destinations {
            app.buttons["sidebar.\(destination)"].click()
            let options = app.descendants(matching: .any)[optionsID]
            XCTAssertTrue(options.waitForExistence(timeout: 3))
            for queueOpen in [false, true] {
                if queueOpen { app.buttons["player.queue"].click() }
                var sidebarClosed = false
                for closeSidebar in [false, true, false] {
                    if closeSidebar != sidebarClosed {
                        app.buttons["navigation.sidebar"].click()
                        sidebarClosed = closeSidebar
                    }
                    XCTAssertGreaterThanOrEqual(options.frame.height, 30,
                        "\(destination): view options shrank at width \(window.frame.width)")
                    XCTAssertGreaterThanOrEqual(options.frame.width, 30)
                    let field = app.textFields["\(search).search.field"]
                    let expand = app.buttons["\(search).search.expand"]
                    if field.exists {
                        XCTAssertGreaterThanOrEqual(field.frame.height, 14)
                    } else {
                        XCTAssertTrue(expand.exists)
                        XCTAssertGreaterThanOrEqual(expand.frame.height, 30)
                    }
                }
                let attachment = XCTAttachment(screenshot: window.screenshot())
                attachment.name = "\(destination) responsive toolbar, queue \(queueOpen)"
                attachment.lifetime = .keepAlways
                add(attachment)
                if queueOpen { app.buttons["player.queue"].click() }
            }
        }
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
    @MainActor
    func testSidebarPlaylistsContextMenuCreatesAndImportsFromHome() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let sidebar = app.buttons["sidebar.playlists"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        if !sidebar.isHittable { app.buttons["navigation.sidebar"].click() }
        let home = app.descendants(matching: .any)["home.page"]
        XCTAssertTrue(home.exists)
        let titles = ["Nova playlist", "Nova playlist inteligente", "Importar playlist"]
        for title in titles {
            sidebar.rightClick()
            for option in titles { XCTAssertTrue(app.menuItems[option].waitForExistence(timeout: 3)) }
            app.menuItems[title].click()
            if title == "Nova playlist" {
                XCTAssertTrue(app.textFields["playlist.new.title"].waitForExistence(timeout: 3))
                app.buttons["Cancelar"].click()
            } else if title == "Nova playlist inteligente" {
                XCTAssertTrue(app.buttons["Adicionar regra"].waitForExistence(timeout: 3))
                app.buttons["Cancelar"].click()
            } else {
                XCTAssertTrue(app.sheets["open-panel"].waitForExistence(timeout: 3))
                app.buttons["CancelButton"].click()
            }
            XCTAssertTrue(home.exists, "A context-menu action must preserve the current page")
        }
        sidebar.click()
        XCTAssertTrue(app.descendants(matching: .any)["playlists.summary"].waitForExistence(timeout: 3),
                      "Normal left click must still navigate to Playlists")
    }

}
