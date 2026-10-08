/// Dictionary-indexed linked order: lookup, removal, promotion and FIFO pop do
/// not scan or shift the remaining entries. Owned by one actor/executor.
final class OrderedKeyedQueue<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        weak var previous: Node?
        var next: Node?
        init(key: Key, value: Value) { self.key = key; self.value = value }
    }

    private var nodes: [Key: Node] = [:]
    private var first: Node?
    private var last: Node?
    var count: Int { nodes.count }

    func value(for key: Key) -> Value? { nodes[key]?.value }

    func append(_ value: Value, for key: Key) {
        let node: Node
        if let existing = nodes[key] {
            unlink(existing)
            existing.value = value
            node = existing
        } else {
            node = Node(key: key, value: value)
            nodes[key] = node
        }
        linkAtEnd(node)
    }

    func moveToEnd(_ key: Key) {
        guard let node = nodes[key], node !== last else { return }
        unlink(node)
        linkAtEnd(node)
    }

    @discardableResult
    func remove(_ key: Key) -> Value? {
        guard let node = nodes.removeValue(forKey: key) else { return nil }
        unlink(node)
        return node.value
    }

    func popFirst() -> (key: Key, value: Value)? {
        guard let node = first else { return nil }
        nodes[node.key] = nil
        unlink(node)
        return (node.key, node.value)
    }

    private func unlink(_ node: Node) {
        if let previous = node.previous { previous.next = node.next }
        else { first = node.next }
        if let next = node.next { next.previous = node.previous }
        else { last = node.previous }
        node.previous = nil
        node.next = nil
    }

    private func linkAtEnd(_ node: Node) {
        node.previous = last
        last?.next = node
        if first == nil { first = node }
        last = node
    }
}

/// Strict byte/count budgets, including zero-cost negative cache entries.
/// Each LRU operation is O(1) on average; inserting may evict multiple entries.
final class CostLimitedLRU<Key: Hashable, Value> {
    private struct Entry { let value: Value; let cost: Int }
    private let entries = OrderedKeyedQueue<Key, Entry>()
    private let byteLimit: Int
    private let countLimit: Int
    private(set) var totalCost = 0
    var count: Int { entries.count }

    init(byteLimit: Int, countLimit: Int) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
    }

    func value(for key: Key) -> Value? {
        guard let entry = entries.value(for: key) else { return nil }
        entries.moveToEnd(key)
        return entry.value
    }

    func insert(_ value: Value, for key: Key, cost: Int) {
        let cost = max(0, cost)
        guard countLimit > 0, cost <= byteLimit else { return }
        if let previous = entries.remove(key) { totalCost -= previous.cost }
        // Evict before adding so accounting cannot overflow, even at Int.max.
        while entries.count >= countLimit || totalCost > byteLimit - cost {
            guard let oldest = entries.popFirst() else { break }
            totalCost -= oldest.value.cost
        }
        entries.append(Entry(value: value, cost: cost), for: key)
        totalCost += cost
    }
}

/// Circular FIFO: dequeue is O(1); enqueue is amortized O(1) as storage grows.
/// Consumed slots are cleared immediately to release continuation captures.
struct CircularFIFO<Value> {
    private var storage: [Value?] = Array(repeating: nil, count: 16)
    private var head = 0
    private(set) var count = 0

    mutating func append(_ value: Value) {
        if count == storage.count {
            var grown: [Value?] = Array(repeating: nil, count: storage.count * 2)
            for offset in 0..<count { grown[offset] = storage[(head + offset) % storage.count] }
            storage = grown
            head = 0
        }
        storage[(head + count) % storage.count] = value
        count += 1
    }

    mutating func popFirst() -> Value? {
        guard count > 0 else { return nil }
        let value = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        if count == 0 { head = 0 }
        return value
    }
}
