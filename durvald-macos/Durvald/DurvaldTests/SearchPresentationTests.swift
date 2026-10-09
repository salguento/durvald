import XCTest
@testable import Durvald

@MainActor
final class SearchPresentationTests: XCTestCase {
    private let immediate = SearchTiming(debounce: .zero, loadingDelay: .zero)

    func testLateBackendCannotReplaceNewQueryOrFinishItsLoadingState() async {
        let model = SearchPresentation<Int>()
        let oldGate = SearchTestGate()
        let newGate = SearchTestGate()
        let old = Task { await model.run(.init(query: "old"), timing: immediate) { _ in await oldGate.wait(); return 1 } }
        await oldGate.waitUntilStarted()
        let new = Task { await model.run(.init(query: "new"), timing: immediate) { _ in await newGate.wait(); return 2 } }
        await newGate.waitUntilStarted()
        await oldGate.release()
        let oldPublished = await old.value
        XCTAssertFalse(oldPublished)
        XCTAssertTrue(model.isPending)
        XCTAssertTrue(model.isSearching)
        XCTAssertNil(model.value)
        await newGate.release()
        let newPublished = await new.value
        XCTAssertTrue(newPublished)
        XCTAssertEqual(model.value, 2)
        XCTAssertEqual(model.committedQuery, "new")
        XCTAssertEqual(model.revision, 1)
        XCTAssertFalse(model.isPending)
        XCTAssertFalse(model.isSearching)
    }

    func testMetadataAndCoreChangesInvalidateResultBeforeReplacementStarts() async {
        let model = SearchPresentation<Int>()
        let firstCore = NSObject()
        let secondCore = NSObject()
        var current = SearchRequest(query: "same", coreID: ObjectIdentifier(firstCore), metadataRevision: 1)
        let original = current
        let gate = SearchTestGate()
        let pending = Task {
            await model.run(original, timing: immediate, isCurrent: { current == original }) { _ in
                await gate.wait(); return 1
            }
        }
        await gate.waitUntilStarted()
        current.coreID = ObjectIdentifier(secondCore)
        current.metadataRevision = 2
        await gate.release()
        let published = await pending.value
        XCTAssertFalse(published)
        XCTAssertNil(model.value)
        XCTAssertEqual(model.committedQuery, "")
        await model.run(current, timing: immediate) { _ in 2 }
        XCTAssertEqual(model.value, 2)
        XCTAssertEqual(model.committedQuery, "same")
    }

    func testDebounceSkipsSupersededBackend() async {
        let gate = SearchTestGate()
        let model = SearchPresentation<Int>(sleep: { _ in await gate.wait() })
        let pending = Task {
            await model.run(.init(query: "partial"), timing: .init(debounce: .milliseconds(80), loadingDelay: .zero)) { _ in
                XCTFail("Superseded query reached backend"); return 1
            }
        }
        await gate.waitUntilStarted()
        await model.run(.init(query: "complete"), timing: immediate) { _ in 2 }
        await gate.release()
        let published = await pending.value
        XCTAssertFalse(published)
        XCTAssertEqual(model.value, 2)
    }

    func testDelayedIndicatorAppearsOnlyWhileCurrentBackendIsPending() async {
        let delay = SearchTestGate()
        let backend = SearchTestGate()
        let model = SearchPresentation<Int>(sleep: { _ in await delay.wait() })
        let pending = Task {
            await model.run(.init(query: "slow"), timing: .init(debounce: .zero, loadingDelay: .milliseconds(200))) { _ in
                await backend.wait(); return 1
            }
        }
        await delay.waitUntilStarted()
        await backend.waitUntilStarted()
        XCTAssertTrue(model.isPending)
        XCTAssertFalse(model.isSearching)
        await delay.release()
        for _ in 0..<1000 where !model.isSearching { await Task.yield() }
        XCTAssertTrue(model.isSearching)
        await backend.release()
        _ = await pending.value
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.isPending)
    }

    func testFastResultCancelsLateIndicator() async {
        let delay = SearchTestGate()
        let backend = SearchTestGate()
        let model = SearchPresentation<Int>(sleep: { _ in await delay.wait() })
        let pending = Task {
            await model.run(.init(query: "fast"), timing: .init(debounce: .zero, loadingDelay: .milliseconds(200))) { _ in
                await backend.wait(); return 1
            }
        }
        await delay.waitUntilStarted()
        await backend.waitUntilStarted()
        await backend.release()
        _ = await pending.value
        await delay.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.value, 1)
        XCTAssertFalse(model.isSearching)
        XCTAssertFalse(model.isPending)
    }

    func testCancellationClearsLoadingWithoutWaitingForNoncooperativeBackend() async {
        let model = SearchPresentation<Int>()
        let gate = SearchTestGate()
        let pending = Task { await model.run(.init(query: "cancel"), timing: immediate) { _ in await gate.wait(); return 1 } }
        await gate.waitUntilStarted()
        pending.cancel()
        for _ in 0..<1000 where model.isPending { await Task.yield() }
        XCTAssertFalse(model.isPending)
        XCTAssertFalse(model.isSearching)
        await model.run(.init(query: "replacement"), timing: immediate) { _ in 2 }
        await gate.release()
        let published = await pending.value
        XCTAssertFalse(published)
        XCTAssertEqual(model.value, 2)
    }

    func testEmptyRemoteQueryClearsAndInvalidatesButLocalHistoryCanLoadAll() async {
        let model = SearchPresentation<Int>()
        await model.run(.init(query: "confirmed"), timing: immediate) { _ in 1 }
        let gate = SearchTestGate()
        let pending = Task { await model.run(.init(query: "pending"), timing: immediate) { _ in await gate.wait(); return 2 } }
        await gate.waitUntilStarted()
        await model.run(.init(query: ""), timing: immediate) { _ in XCTFail("Empty remote search"); return 3 }
        XCTAssertNil(model.value)
        XCTAssertEqual(model.committedQuery, "")
        XCTAssertFalse(model.isPending)
        await gate.release()
        let published = await pending.value
        XCTAssertFalse(published)
        await model.run(.init(query: ""), timing: immediate, allowsEmpty: true) { query in
            XCTAssertEqual(query, ""); return 4
        }
        XCTAssertEqual(model.value, 4)
        XCTAssertEqual(model.committedQuery, "")
    }

    func testBackendErrorKeepsConfirmedResultAndRetryClearsError() async {
        let model = SearchPresentation<Int>()
        await model.run(.init(query: "confirmed"), timing: immediate) { _ in 1 }
        let published = await model.run(.init(query: "retry"), timing: immediate) { _ in
            throw NSError(domain: "SearchTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unavailable"])
        }
        XCTAssertFalse(published)
        XCTAssertEqual(model.errorMessage, "Unavailable")
        XCTAssertEqual(model.value, 1)
        XCTAssertEqual(model.committedQuery, "confirmed")
        XCTAssertFalse(model.isPending)
        await model.run(.init(query: "retry"), timing: immediate) { _ in 2 }
        XCTAssertEqual(model.value, 2)
        XCTAssertEqual(model.committedQuery, "retry")
        XCTAssertNil(model.errorMessage)
    }
}

/// Intentionally ignores cancellation to exercise publication guards independently of the backend.
private actor SearchTestGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation {
            pending = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}
