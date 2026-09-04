import XCTest
import AppKit

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
        let indicator = app.images["album.track.100.playbackIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 3))
        XCTAssertEqual(indicator.label, "Faixa atual, pausada")
        XCTAssertFalse(app.staticTexts["album.track.100.number"].exists)
        let albumCapture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        albumCapture.name = "Album active track indicator"
        albumCapture.lifetime = .keepAlways
        add(albumCapture)
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
    func testScrollEffectAcrossLibraryAndQueue() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "--ui-testing", "--player-navigation-fixture", "--scroll-effect-fixture",
            "-AppleInterfaceStyle", "Dark"
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
        app.buttons["Hide Sidebar"].click()
        XCTAssertTrue(app.buttons["Show Sidebar"].waitForExistence(timeout: 3))
        capture("Albums scrolled without sidebar")
        app.buttons["Show Sidebar"].click()
        XCTAssertTrue(app.buttons["sidebar.songs"].waitForExistence(timeout: 3))

        app.buttons["sidebar.songs"].click()
        XCTAssertTrue(app.buttons["track.100"].waitForExistence(timeout: 3))
        let initialTrackFrame = app.buttons["track.100"].frame
        let rowHeight = app.buttons["track.101"].frame.minY - initialTrackFrame.minY
        capture("Songs at top")
        app.outlines.firstMatch.scroll(byDeltaX: 0, deltaY: -350)
        capture("Songs scrolled")

        // Compare identical title styling under the toolbar and one row below it.
        // This catches a transparent toolbar even when navigation/scrolling work.
        // Use the original row geometry: recycled List accessibility elements
        // can report stale frames after scrolling. Seven rows moved exactly 350 pt.
        let clearTitle = CGRect(x: initialTrackFrame.midX, y: initialTrackFrame.minY,
                                width: initialTrackFrame.width / 2, height: 14)
        let coveredTitle = clearTitle.offsetBy(dx: 0, dy: -rowHeight)
        XCTAssertLessThan(coveredTitle.maxY, app.toolbars.firstMatch.frame.maxY)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: window.screenshot().pngRepresentation))
        let coveredHighlight = try textHighlight(in: coveredTitle, window: window.frame, bitmap: bitmap)
        let clearHighlight = try textHighlight(in: clearTitle, window: window.frame, bitmap: bitmap)
        XCTAssertGreaterThan(clearHighlight, 0.45)
        XCTAssertLessThan(coveredHighlight, clearHighlight * 0.75,
                          "O texto sob a toolbar precisa ser atenuado pelo efeito nativo.")

        app.outlines.firstMatch.scroll(byDeltaX: 0, deltaY: 3000)
        XCTAssertEqual(app.buttons["track.100"].frame.minY, initialTrackFrame.minY, accuracy: 2)
        capture("Songs returned to top")
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
        if app.buttons["Show Sidebar"].exists {
            app.buttons["Show Sidebar"].click()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        let splitter = app.splitters.firstMatch
        XCTAssertTrue(splitter.exists)

        for targetWidth: CGFloat in [190, 280] {
            let handle = splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let offset = window.frame.minX + 8 + targetWidth - splitter.frame.midX
            handle.press(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: offset, dy: 0)))
            let originalPickerWidth = picker.frame.width
            let originalWindowWidth = window.frame.width
            for section in ["playlists", "albums", "artists", "navigation"] {
                app.buttons["sidebar.section.\(section)"].click()
                XCTAssertEqual(picker.frame.width, originalPickerWidth, accuracy: 1,
                               "Changing tabs must not resize the sidebar.")
                XCTAssertEqual(window.frame.width, originalWindowWidth, accuracy: 1)
            }
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = targetWidth < 200 ? "Narrow sidebar icons" : "Wide sidebar label"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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

        app.buttons["sidebar.songs"].click()
        XCTAssertTrue(app.buttons["track.100"].waitForExistence(timeout: 3))
        XCTAssertFalse(forward.isEnabled)
        app.typeKey(.rightArrow, modifierFlags: .command)
        XCTAssertTrue(app.buttons["track.100"].exists)
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

        app.buttons["Hide Sidebar"].click()
        XCTAssertTrue(app.buttons["Show Sidebar"].waitForExistence(timeout: 3))
        app.typeKey("k", modifierFlags: .command)
        expectation(for: focused, evaluatedWith: field)
        waitForExpectations(timeout: 3)
        app.typeKey("a", modifierFlags: .command)
        app.typeText("digitavel")
        XCTAssertEqual(field.value as? String, "digitavel")
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
