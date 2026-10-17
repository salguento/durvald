import XCTest

final class CollectionTrackRowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPlaylistAndAlbumShareHoverControlsAndPersistPersonalValues() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture", "--collection-track-fixture"]
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        defer { app.terminate() }
        let playlist = app.buttons["sidebar.playlist.1"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 10))
        if !playlist.isHittable { app.buttons["navigation.sidebar"].click() }
        playlist.click()
        let row = app.descendants(matching: .any)["playlist.track.1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let favorite = row.buttons["collection.track.1.favorite"]
        let rating = row.descendants(matching: .any)["collection.track.1.rating"].firstMatch
        let duration = row.staticTexts["collection.track.1.duration"]
        let options = row.descendants(matching: .any)["collection.track.1.options"].firstMatch

        app.buttons["sidebar.home"].hover()
        XCTAssertFalse(favorite.exists)
        XCTAssertFalse(rating.buttons["rating.halfSteps.1"].exists)
        XCTAssertTrue(duration.exists)
        XCTAssertTrue(options.exists)
        let originalDurationFrame = duration.frame
        row.hover()
        XCTAssertTrue(favorite.waitForExistence(timeout: 3))
        XCTAssertTrue(rating.waitForExistence(timeout: 3))
        XCTAssertLessThan(favorite.frame.maxX, rating.frame.minX)
        XCTAssertLessThan(rating.frame.maxX, duration.frame.minX)
        XCTAssertLessThan(duration.frame.maxX, options.frame.minX)
        XCTAssertEqual(duration.frame, originalDurationFrame, "Hover must reserve the controls' layout slots")
        XCTAssertFalse(row.buttons["Adicionar Rating track 001 à fila"].exists)

        favorite.click()
        row.hover()
        let half = rating.buttons["rating.halfSteps.9"]
        XCTAssertTrue(half.waitForExistence(timeout: 3))
        half.click()
        app.buttons["sidebar.home"].hover()
        XCTAssertTrue(favorite.waitForExistence(timeout: 3), "A populated favorite remains visible without hover")
        XCTAssertTrue(rating.exists, "A populated rating remains visible without hover")
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: half)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        XCTAssertEqual(favorite.value as? String, "Favorita")

        options.click()
        XCTAssertTrue(app.menuItems["Adicionar à fila"].waitForExistence(timeout: 3))
        app.menuItems["Ir ao álbum"].click()
        let albumRow = app.descendants(matching: .any)["album.track.1"].firstMatch
        XCTAssertTrue(albumRow.waitForExistence(timeout: 5))
        app.buttons["sidebar.home"].hover()
        XCTAssertTrue(albumRow.buttons["collection.track.1.favorite"].exists)
        let albumRating = albumRow.descendants(matching: .any)["collection.track.1.rating"].firstMatch
        XCTAssertTrue(albumRating.buttons["rating.halfSteps.9"].isSelected)
        let albumDuration = albumRow.staticTexts["collection.track.1.duration"]
        let albumOptions = albumRow.descendants(matching: .any)["collection.track.1.options"].firstMatch
        XCTAssertLessThan(albumRating.frame.maxX, albumDuration.frame.minX)
        XCTAssertLessThan(albumDuration.frame.maxX, albumOptions.frame.minX)
        XCTAssertFalse(albumRow.buttons["Adicionar Rating track 001 à fila"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Shared album track row with populated personal controls"
        capture.lifetime = .keepAlways
        add(capture)

        playlist.click()
        let albumLink = row.descendants(matching: .any)["collection.track.1.album"].firstMatch
        XCTAssertTrue(albumLink.waitForExistence(timeout: 5))
        XCTAssertEqual(albumLink.label, "Rating album 1")
        albumLink.click()
        XCTAssertTrue(albumRow.waitForExistence(timeout: 5))
        let artistLink = albumRow.descendants(matching: .any)["collection.track.1.artist"].firstMatch
        XCTAssertTrue(artistLink.exists)
        XCTAssertEqual(artistLink.label, "Rating fixture")
        artistLink.click()
        XCTAssertTrue(app.descendants(matching: .any)["artist.detail.1"].firstMatch.waitForExistence(timeout: 5))
    }
}
