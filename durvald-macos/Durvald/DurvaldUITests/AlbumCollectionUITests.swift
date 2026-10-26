import XCTest

final class AlbumCollectionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testManualCreateAddReorderRenameAndPersistence() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture", "-albums.minimumRating.halfSteps", "0"]
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = UUID().uuidString
        app.launch(); defer { app.terminate() }
        let sidebar = app.buttons["sidebar.albumCollections"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.click()
        let create = app.buttons["albumCollections.empty.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 8)); create.click()
        let name = app.textFields["albumCollection.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.click(); name.typeText("Viagens")
        app.buttons["albumCollection.editor.save"].click()
        let add = app.buttons["albumCollection.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 8)); add.click()
        let pick1 = app.checkBoxes["albumCollection.pick.1"]
        XCTAssertTrue(pick1.waitForExistence(timeout: 8)); pick1.click()
        app.checkBoxes["albumCollection.pick.2"].click()
        app.buttons["albumCollection.picker.add"].click()
        let row1 = app.descendants(matching: .any)["albumCollection.item.1"].firstMatch
        let row2 = app.descendants(matching: .any)["albumCollection.item.2"].firstMatch
        XCTAssertTrue(row2.waitForExistence(timeout: 8))
        app.buttons["albumCollection.up.2"].click()
        expectation(for: NSPredicate { _, _ in row2.frame.minY < row1.frame.minY }, evaluatedWith: row2)
        waitForExpectations(timeout: 5)
        app.buttons["albumCollection.edit"].click()
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.click()
        app.typeKey("a", modifierFlags: .command); name.typeText("Viagens completas")
        app.buttons["albumCollection.editor.save"].click()
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Coleção manual"; capture.lifetime = .keepAlways; self.add(capture)
        app.terminate(); app.launch()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.click()
        let collection = app.buttons["albumCollection.1"]
        XCTAssertTrue(collection.waitForExistence(timeout: 8)); collection.click()
        XCTAssertTrue(row2.waitForExistence(timeout: 8)); XCTAssertLessThan(row2.frame.minY, row1.frame.minY)
        app.buttons["albumCollection.remove.2"].click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row2)
        waitForExpectations(timeout: 5)
    }

    @MainActor func testCreateSmartCollectionAndAddAlbumThroughContextMenu() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--ratings-integration-fixture", "-albums.minimumRating.halfSteps", "0"]
        app.launchEnvironment["DURVALD_RATING_FIXTURE_ID"] = UUID().uuidString
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["sidebar.albumCollections"].waitForExistence(timeout: 15))
        app.buttons["sidebar.albumCollections"].click()
        let create = app.buttons["albumCollections.empty.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 8)); create.click()
        let name = app.textFields["albumCollection.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.click(); name.typeText("Artista favorito")
        app.radioButtons["Inteligente"].click()
        let value = app.textFields["albumCollection.editor.ruleValue"]
        XCTAssertTrue(value.waitForExistence(timeout: 5)); value.click(); value.typeText("Rating fixture")
        app.buttons["albumCollection.editor.save"].click()
        XCTAssertTrue(app.descendants(matching: .any)["albumCollection.item.7"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["albumCollection.add"].exists)
        app.typeKey("3", modifierFlags: .command)
        let album = app.buttons["album.1"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 8)); album.rightClick()
        app.menuItems["Adicionar à coleção…"].click()
        let quickName = app.textFields["albumCollection.quick.name"]
        XCTAssertTrue(quickName.waitForExistence(timeout: 8)); quickName.click(); quickName.typeText("Manual pelo álbum")
        app.buttons["albumCollection.quick.create"].click()
        app.buttons["sidebar.albumCollections"].click()
        let manual = app.buttons["albumCollection.2"]
        XCTAssertTrue(manual.waitForExistence(timeout: 8)); manual.click()
        XCTAssertTrue(app.buttons["albumCollection.add"].waitForExistence(timeout: 8))
    }
}
