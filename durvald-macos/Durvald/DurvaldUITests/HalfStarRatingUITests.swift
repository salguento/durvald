import XCTest

/// Exercises production controls against a real core in an isolated database.
final class HalfStarRatingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testHalfStarInputCancelBothRoundingChoicesAndPreferenceSurviveRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture"]
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = UUID().uuidString
        defer { app.terminate() }

        func launchSongs() {
            app.launch()
            let songs = app.buttons["sidebar.songs"]
            XCTAssertTrue(songs.waitForExistence(timeout: 10))
            if !songs.isHittable { app.buttons["navigation.sidebar"].click() }
            songs.click()
            XCTAssertTrue(app.buttons["track.4.rating.5"].waitForExistence(timeout: 10))
        }
        func expectRating(_ id: Int, _ halfSteps: Int) {
            let stars = Double(halfSteps) / 2
            let number = halfSteps.isMultiple(of: 2) ? String(halfSteps / 2) : String(stars)
            let button = app.buttons["track.\(id).rating.5"]
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (button.value as? String)?.replacingOccurrences(of: ",", with: ".") == "\(number) de 5"
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        }
        func settings() -> XCUIElement {
            app.typeKey(",", modifierFlags: .command)
            let picker = app.popUpButtons["settings.ratings.scale"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: picker)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
            return picker
        }
        func select(_ title: String, picker: XCUIElement) {
            picker.click()
            app.menuItems[title].click()
        }

        launchSongs()
        let star = app.buttons["track.4.rating.5"]
        star.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
        expectRating(4, 9) // left half of star five = 4.5
        app.terminate()
        launchSongs()
        expectRating(4, 9)

        var picker = settings()
        select("Apenas estrelas inteiras", picker: picker)
        XCTAssertTrue(app.sheets.buttons["Arredondar para cima"].waitForExistence(timeout: 5))
        app.sheets.buttons["Cancelar"].click()
        XCTAssertTrue((picker.value as? String ?? picker.label).contains("meia"))
        expectRating(4, 9)

        select("Apenas estrelas inteiras", picker: picker)
        app.sheets.buttons["Arredondar para baixo"].click()
        XCTAssertTrue((picker.value as? String ?? picker.label).contains("inteiras"))
        expectRating(4, 8)
        app.typeKey("w", modifierFlags: .command)
        app.buttons["track.4.rating.5"].coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
        expectRating(4, 10) // the left half selects a full star in whole-star mode

        app.terminate()
        launchSongs()
        picker = settings()
        XCTAssertTrue((picker.value as? String ?? picker.label).contains("inteiras"))
        XCTAssertTrue((picker.value as? String ?? picker.label).contains("inteiras"))
        select("De meia em meia estrela", picker: picker)
        XCTAssertTrue((picker.value as? String ?? picker.label).contains("meia"))
        expectRating(4, 10) // switching back must not recreate the old fraction
        app.typeKey("w", modifierFlags: .command)
        app.buttons["track.4.rating.4"].coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
        expectRating(4, 7)
        picker = settings()
        select("Apenas estrelas inteiras", picker: picker)
        app.sheets.buttons["Arredondar para cima"].click()
        XCTAssertTrue((picker.value as? String ?? picker.label).contains("inteiras"))
        expectRating(4, 8)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Ratings scale after real core conversion"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testAlbumHalfStarControlPersistsAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture"]
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = UUID().uuidString
        defer { app.terminate() }
        func openAlbum() -> XCUIElement {
            app.launch()
            let songs = app.buttons["sidebar.songs"]
            XCTAssertTrue(songs.waitForExistence(timeout: 10))
            if !songs.isHittable { app.buttons["navigation.sidebar"].click() }
            songs.click()
            let star = app.buttons["track.4.rating.5"]
            XCTAssertTrue(star.waitForExistence(timeout: 10))
            star.rightClick()
            app.menuItems["Ir ao álbum"].click()
            let rating = app.descendants(matching: .any)["album.rating"].firstMatch
            XCTAssertTrue(rating.waitForExistence(timeout: 10))
            return rating
        }
        func expectHalfRating(_ rating: XCUIElement) {
            let target = rating.buttons["rating.halfSteps.9"]
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: target)
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        }
        var rating = openAlbum()
        let half = rating.buttons["rating.halfSteps.9"]
        XCTAssertTrue(half.waitForExistence(timeout: 5))
        half.click()
        expectHalfRating(rating)
        app.terminate()
        rating = openAlbum()
        expectHalfRating(rating)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Persisted half-star album rating"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
