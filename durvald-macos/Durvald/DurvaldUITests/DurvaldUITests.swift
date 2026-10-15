import XCTest
import AppKit

final class DurvaldUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTemporaryToolbarAppearanceReference() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let sidebarButton = app.buttons["navigation.sidebar"]
        XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
        let addButtons = app.buttons.matching(identifier: "library.addMenu")
        XCTAssertTrue(addButtons.firstMatch.waitForExistence(timeout: 3))
        guard let openAddButton = addButtons.allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("O botão de adicionar visível não foi encontrado")
            return
        }
        XCTAssertTrue(openAddButton.isHittable)
        let openAttachment = XCTAttachment(screenshot: window.screenshot())
        openAttachment.name = "Toolbar sidebar open reference"
        openAttachment.lifetime = .keepAlways
        add(openAttachment)

        sidebarButton.click()
        XCTAssertTrue(sidebarButton.waitForExistence(timeout: 3))
        guard let closedAddButton = addButtons.allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("O botão de adicionar visível não foi encontrado")
            return
        }
        XCTAssertTrue(closedAddButton.isHittable)

        let closedAttachment = XCTAttachment(screenshot: window.screenshot())
        closedAttachment.name = "Toolbar sidebar closed reference"
        closedAttachment.lifetime = .keepAlways
        add(closedAttachment)
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
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
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
        // Commands still work in the search editor and increasing volume unmutes.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.buttons["sidebar.search.open"].exists)
        XCTAssertTrue(app.buttons["navigation.back"].exists)
        XCTAssertTrue(app.buttons["navigation.forward"].exists)
    }

    @MainActor
    func testCommandArrowsFollowAvailableNavigationHistory() {
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
        app.typeKey(.leftArrow, modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: .command)
        XCTAssertTrue(home.exists)

        app.buttons["player.artwork"].click()
        XCTAssertTrue(album.waitForExistence(timeout: 3))
        app.typeKey(.leftArrow, modifierFlags: .command)
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertFalse(back.isEnabled)
        XCTAssertTrue(forward.isEnabled)
        app.typeKey(.rightArrow, modifierFlags: .command)
        XCTAssertTrue(album.waitForExistence(timeout: 3))
        XCTAssertFalse(forward.isEnabled)

        // Navigation shortcuts must work even while the search editor has focus.
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        app.typeText("teste")
        app.typeKey(.leftArrow, modifierFlags: .command)
        XCTAssertTrue(album.waitForExistence(timeout: 3))
        XCTAssertTrue(forward.isEnabled)

        app.buttons["sidebar.home"].click()
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertFalse(forward.isEnabled)
        app.typeKey(.rightArrow, modifierFlags: .command)
        XCTAssertTrue(home.exists)
        XCTAssertFalse(field.exists)
    }

    @MainActor
    func testCommandKOpensSearchAndRefocusesWithSidebarHidden() {
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
    func testArtistToolbarWorksWhenOpenedDirectlyAndPanelsToggle() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
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
    func testQueueToggleKeepsEightPointTrailingInsetAcrossPages() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let toggle = app.buttons["player.queue"]
        for destination in ["home", "search.open", "songs", "albums", "artists", "playlists", "retrospective"] {
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
}
