import XCTest
@testable import Durvald

final class ArtworkCacheStructureTests: XCTestCase {
    func testLinkedOrderHandlesRemovalPromotionAndReplacementWithoutDuplicates() {
        let order = OrderedKeyedQueue<String, Int>()
        order.append(1, for: "a"); order.append(2, for: "b"); order.append(3, for: "c")
        XCTAssertEqual(order.remove("b"), 2)
        order.moveToEnd("a")
        order.append(30, for: "c")
        order.append(4, for: "d")
        XCTAssertEqual(order.count, 3)
        XCTAssertEqual(order.value(for: "c"), 30)
        XCTAssertEqual(order.popFirst()?.key, "a")
        XCTAssertEqual(order.popFirst()?.value, 30)
        XCTAssertEqual(order.popFirst()?.key, "d")
        XCTAssertNil(order.popFirst())
        XCTAssertNil(order.remove("missing"))
        order.moveToEnd("missing")
        order.append(5, for: "only")
        order.moveToEnd("only")
        XCTAssertEqual(order.remove("only"), 5)
        XCTAssertEqual(order.count, 0)
        order.append(6, for: "after-empty")
        XCTAssertEqual(order.popFirst()?.value, 6)
    }

    func testLRUHitProtectsEntryAndEvictsLeastRecentlyUsed() {
        let cache = CostLimitedLRU<String, Int>(byteLimit: 10, countLimit: 2)
        cache.insert(1, for: "a", cost: 2)
        cache.insert(2, for: "b", cost: 2)
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.insert(3, for: "c", cost: 2)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "c"), 3)
        XCTAssertEqual(cache.totalCost, 4)
        XCTAssertEqual(cache.count, 2)
    }

    func testReplacingEntryUpdatesCostAndOversizedReplacementKeepsPreviousValue() {
        let cache = CostLimitedLRU<String, Int>(byteLimit: 5, countLimit: 2)
        cache.insert(1, for: "a", cost: 2)
        cache.insert(2, for: "b", cost: 2)
        cache.insert(10, for: "a", cost: 3)
        XCTAssertEqual(cache.totalCost, 5)
        cache.insert(100, for: "a", cost: 6)
        XCTAssertEqual(cache.value(for: "a"), 10)
        XCTAssertEqual(cache.totalCost, 5)
        cache.insert(3, for: "c", cost: 2)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "a"), 10)
        XCTAssertEqual(cache.count, 2)
    }

    func testByteBudgetCanEvictMultipleEntriesAndRemainsStrict() {
        let cache = CostLimitedLRU<String, Int>(byteLimit: 5, countLimit: 10)
        cache.insert(1, for: "a", cost: 3)
        cache.insert(2, for: "b", cost: 1)
        cache.insert(3, for: "c", cost: 1)
        cache.insert(4, for: "d", cost: 4)
        XCTAssertNil(cache.value(for: "a"))
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "c"), 3)
        XCTAssertEqual(cache.value(for: "d"), 4)
        XCTAssertEqual(cache.totalCost, 5)
        XCTAssertEqual(cache.count, 2)
    }

    func testZeroCostNegativeCacheStillRespectsCountAndDisabledCache() {
        let cache = CostLimitedLRU<String, Int>(byteLimit: 0, countLimit: 1)
        cache.insert(1, for: "a", cost: 0)
        cache.insert(2, for: "b", cost: -1)
        XCTAssertNil(cache.value(for: "a"))
        XCTAssertEqual(cache.value(for: "b"), 2)
        XCTAssertEqual(cache.totalCost, 0)
        XCTAssertEqual(cache.count, 1)
        let disabled = CostLimitedLRU<String, Int>(byteLimit: 100, countLimit: 0)
        disabled.insert(1, for: "a", cost: 0)
        XCTAssertNil(disabled.value(for: "a"))
    }

    func testAccountingDoesNotOverflowAtMaximumBudget() {
        let cache = CostLimitedLRU<String, Int>(byteLimit: Int.max, countLimit: 10)
        cache.insert(1, for: "a", cost: Int.max)
        cache.insert(2, for: "b", cost: Int.max - 1)
        cache.insert(3, for: "c", cost: 1)
        XCTAssertEqual(cache.totalCost, Int.max)
        cache.insert(4, for: "d", cost: 1)
        XCTAssertEqual(cache.totalCost, 2)
        XCTAssertNil(cache.value(for: "a"))
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.count, 2)
    }

    func testLinkedOrderReleasesRemovedValuesAndHasNoRetainCycle() {
        var order: OrderedKeyedQueue<Int, NSObject>? = OrderedKeyedQueue()
        var removed: NSObject? = NSObject()
        let removedReference = WeakArtworkReference(removed!)
        order?.append(removed!, for: 1)
        removed = nil
        order?.remove(1)
        XCTAssertNil(removedReference.value)
        var retained: NSObject? = NSObject()
        let retainedReference = WeakArtworkReference(retained!)
        order?.append(retained!, for: 2)
        order?.append(NSObject(), for: 3)
        retained = nil
        XCTAssertNotNil(retainedReference.value)
        order = nil
        XCTAssertNil(retainedReference.value)
    }

    func testCircularFIFOHandlesWrapGrowthEmptyReuseAndReleasesConsumedValues() {
        var queue = CircularFIFO<Int>()
        for value in 0..<20 { queue.append(value) }
        for value in 0..<15 { XCTAssertEqual(queue.popFirst(), value) }
        for value in 20..<60 { queue.append(value) }
        for value in 15..<60 { XCTAssertEqual(queue.popFirst(), value) }
        XCTAssertEqual(queue.count, 0)
        XCTAssertNil(queue.popFirst())
        queue.append(100)
        XCTAssertEqual(queue.popFirst(), 100)
        var references = CircularFIFO<NSObject>()
        var object: NSObject? = NSObject()
        let reference = WeakArtworkReference(object!)
        references.append(object!)
        object = nil
        XCTAssertNotNil(reference.value)
        _ = references.popFirst()
        XCTAssertNil(reference.value)
    }

    func testGatePreservesFIFOAndKeepsOneOwnerUntilRelease() async {
        let gate = ArtworkLoadGate()
        await gate.acquire()
        let first = Task { await gate.acquire(); return 1 }
        await waitForQueued(1, gate: gate)
        let second = Task { await gate.acquire(); return 2 }
        await waitForQueued(2, gate: gate)
        await gate.release()
        let firstValue = await first.value
        XCTAssertEqual(firstValue, 1)
        let waiting = await gate.waitingCount
        XCTAssertEqual(waiting, 1)
        await gate.release()
        let secondValue = await second.value
        XCTAssertEqual(secondValue, 2)
        await gate.release()
        await gate.acquire()
        let empty = await gate.waitingCount
        XCTAssertEqual(empty, 0)
        await gate.release()
    }

    private func waitForQueued(_ count: Int, gate: ArtworkLoadGate) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while await gate.waitingCount != count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let actual = await gate.waitingCount
        XCTAssertEqual(actual, count)
    }
}

private final class WeakArtworkReference {
    weak var value: NSObject?
    init(_ value: NSObject) { self.value = value }
}
