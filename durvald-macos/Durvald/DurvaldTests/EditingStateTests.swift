import XCTest
@testable import Durvald

final class EditingStateTests: XCTestCase {
    private let source = TrackMetadataEdit(title: "Title", artist: "Artist", albumArtist: "Artist", album: "Album",
        genre: "Rock", year: 2024, trackNumber: 7, discNumber: 2, composer: "Composer", comment: "Comment")
    func testRemoteRefreshKeepsEditsAndSameSourceReappearanceDoesNotReset() {
        let source = NSObject()
        var state = EditingState("original")
        state.refresh("original", sourceID: ObjectIdentifier(source))
        state.value = "local"
        state.refresh("remote", sourceID: ObjectIdentifier(source))
        XCTAssertEqual(state.value, "local")
        XCTAssertEqual(state.baseline, "remote")
        XCTAssertTrue(state.isDirty)
        state.reset(to: state.baseline)
        state.receive("next")
        XCTAssertEqual(state.value, "next")
        XCTAssertFalse(state.isDirty)
    }

    func testSaveAcknowledgementNormalizesSubmittedValueButPreservesLaterEdits() {
        var state = EditingState("original")
        state.value = " submitted "
        let first = state.beginSaving()!
        state.finish(first, confirmed: "submitted")
        XCTAssertEqual(state.value, "submitted")
        XCTAssertFalse(state.isDirty)
        state.value = "save"
        let second = state.beginSaving()!
        state.value = "newer edit"
        state.receive("save")
        state.finish(second, confirmed: "save")
        XCTAssertEqual(state.value, "newer edit")
        XCTAssertEqual(state.baseline, "save")
        XCTAssertTrue(state.isDirty)
        XCTAssertFalse(state.isSaving)
    }

    func testFailureRetainsDraftAndBaselineAndAllowsRetryWithoutOverlappingSaves() {
        var state = EditingState("original")
        state.value = "edit"
        let first = state.beginSaving()!
        XCTAssertNil(state.beginSaving())
        state.fail(first, message: "Offline")
        XCTAssertEqual(state.value, "edit")
        XCTAssertEqual(state.baseline, "original")
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(state.errorMessage, "Offline")
        let retry = state.beginSaving()!
        XCTAssertNil(state.errorMessage)
        state.finish(retry, confirmed: "edit")
        XCTAssertFalse(state.isDirty)
        XCTAssertFalse(state.isSaving)
    }

    func testSourceChangeRejectsOldSuccessAndFailureWithoutEndingNewSave() {
        let firstSource = NSObject(), secondSource = NSObject()
        var state = EditingState("first")
        state.refresh("first", sourceID: ObjectIdentifier(firstSource))
        state.value = "old edit"
        let old = state.beginSaving()!
        state.refresh("second", sourceID: ObjectIdentifier(secondSource))
        XCTAssertFalse(state.isSaving)
        XCTAssertFalse(state.isDirty)
        state.value = "new edit"
        let new = state.beginSaving()!
        XCTAssertFalse(state.finish(old, confirmed: "old edit"))
        XCTAssertFalse(state.fail(old, message: "Old error"))
        XCTAssertTrue(state.isSaving)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.value, "new edit")
        state.finish(new, confirmed: "new edit")
        XCTAssertFalse(state.isDirty)
    }

    func testCleanUndoRemainsProtectedFromRefreshWhileWorking() {
        var state = EditingState("saved")
        let undo = state.beginSaving()!
        state.receive("external")
        XCTAssertEqual(state.value, "saved")
        XCTAssertTrue(state.isSaving)
        state.finish(undo, confirmed: "restored")
        XCTAssertEqual(state.value, "restored")
        XCTAssertFalse(state.isDirty)
    }

    func testBatchDirtyMeansEnabledFieldsIncludingExplicitClearing() throws {
        var batch = BatchMetadataDraft()
        batch.genre.isMixed = true
        var state = EditingState<BatchMetadataDraft?>(batch, isDirty: { value, _ in value?.hasChanges == true })
        state.value?.genre.text = "unsent"
        XCTAssertFalse(state.isDirty)
        XCTAssertTrue(state.value?.genre.isMixed == true)
        state.value?.genre.isEnabled = true
        state.value?.genre.isMixed = false
        state.value?.genre.text = ""
        XCTAssertTrue(state.isDirty)
        XCTAssertEqual(try state.value?.applying(to: source).genre, "")
        let ticket = state.beginSaving()!
        state.finish(ticket, confirmed: BatchMetadataDraft())
        XCTAssertFalse(state.isDirty)
    }

    func testSingleAndBatchNumericValidationAgreeWithoutChangingUnselectedFields() throws {
        for text in ["", " 2026 ", "0", "10000", "abc", "-1"] {
            var single = TrackMetadataDraft(source)
            single.year = text
            var batch = BatchMetadataDraft()
            batch.year.isEnabled = true
            batch.year.text = text
            let singleResult = Result { try single.metadata().year }
            let batchResult = Result { try batch.applying(to: source).year }
            switch (singleResult, batchResult) {
            case (.success(let first), .success(let second)): XCTAssertEqual(first, second)
            case (.failure(let first), .failure(let second)): XCTAssertEqual(first.localizedDescription, second.localizedDescription)
            default: XCTFail("Single/batch validation differs for \(text)")
            }
        }
        let unchanged = try BatchMetadataDraft().applying(to: source)
        XCTAssertEqual(unchanged, source)
    }
}
