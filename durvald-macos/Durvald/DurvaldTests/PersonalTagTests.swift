import XCTest
@testable import Durvald

final class PersonalTagTests: XCTestCase {
    func testAnyAndAllFiltersTreatDuplicateLinksAsOneAndDoNotInheritAlbumTags() {
        let links = [UserTagLink(tagId: 1, itemId: 11), UserTagLink(tagId: 2, itemId: 11),
                     UserTagLink(tagId: 1, itemId: 12), UserTagLink(tagId: 1, itemId: 12)]
        var filter = PersonalTagFilter()
        XCTAssertNil(filter.matchingIDs(in: links))
        filter.ids = [1, 2]
        XCTAssertEqual(filter.matchingIDs(in: links), [11])
        filter.matchAll = false
        XCTAssertEqual(filter.matchingIDs(in: links), [11, 12])
        filter.matchAll = true
        filter.ids = [1, 99]
        XCTAssertEqual(filter.matchingIDs(in: links), [])
        XCTAssertEqual(filter.matchingIDs(in: []), [])
    }

    @MainActor
    func testStorePersistsBatchChangesAndKeepsOtherTags() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DurvaldPersonalTags-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await RatingIntegrationFixture.makeStore(directory: directory)
        let selection = PersonalTagSelection(trackIDs: [1, 2])
        let created = await store.createPersonalTag("Noite", selection: selection)
        XCTAssertTrue(created)
        let other = await store.createPersonalTag("Viagem", selection: PersonalTagSelection(trackIDs: [1], releaseIDs: [1]))
        XCTAssertTrue(other)
        let night = try XCTUnwrap(store.personalTags.tags.first { $0.name == "Noite" })
        let trip = try XCTUnwrap(store.personalTags.tags.first { $0.name == "Viagem" })
        await store.attachPersonalTag(night, to: PersonalTagSelection(trackIDs: [1]), attached: false)
        XCTAssertEqual(store.associationCount(night, in: selection), 1)
        XCTAssertEqual(store.associationCount(trip, in: selection), 1)
        let renamed = await store.changePersonalTags { _ = try await $0.renameUserTag(tagId: trip.id, name: "Estrada") }
        XCTAssertTrue(renamed)
        XCTAssertTrue(store.tags(for: PersonalTagSelection(releaseIDs: [1])).contains { $0.name == "Estrada" })
        let reopened = try await RatingIntegrationFixture.makeStore(directory: directory)
        await reopened.refreshPersonalTags()
        XCTAssertEqual(reopened.personalTags, store.personalTags)
    }
}
