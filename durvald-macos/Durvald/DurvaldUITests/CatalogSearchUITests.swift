import XCTest

final class CatalogSearchUITests: XCTestCase {
    @MainActor
    func testExploreShowsIndependentProvidersAndEntityFilters() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing", "--player-navigation-fixture", "--catalog-search-fixture"]
        app.launch()
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Artista de teste")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["search.page"].waitForExistence(timeout: 5))
        let explore = app.radioButtons["Explorar"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        explore.click()
        XCTAssertTrue(app.descendants(matching: .any)["catalog.provider.library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["catalog.provider.musicbrainz"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Abrir no MusicBrainz")).firstMatch.waitForExistence(timeout: 5))
        app.radioButtons["Faixas"].click()
        XCTAssertTrue(app.staticTexts["Faixa · MusicBrainz"].waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Busca de catálogo local e MusicBrainz"
        capture.lifetime = .keepAlways
        add(capture)
    }
}
