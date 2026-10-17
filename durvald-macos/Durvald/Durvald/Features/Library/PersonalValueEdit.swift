import Foundation

/// Shared optimistic reducer. Acknowledgements may belong to an older click or
/// to a cell's previous identity; neither may replace a newer visible edit.
struct PersonalValueEdit<Value: Equatable> {
    struct Ticket {
        fileprivate let generation: UUID
        fileprivate let revision: UInt64
        let value: Value
    }
    private var generation = UUID()
    private var revision: UInt64 = 0
    private var pending: UInt64?
    private var confirmedRevision: UInt64 = 0
    private var snapshot: Value
    private(set) var confirmed: Value
    private(set) var value: Value

    init(_ value: Value) { snapshot = value; confirmed = value; self.value = value }

    var isPending: Bool { pending != nil }

    mutating func begin(_ value: Value) -> Ticket {
        revision &+= 1
        pending = revision
        self.value = value
        return Ticket(generation: generation, revision: revision, value: value)
    }

    mutating func finish(_ ticket: Ticket, succeeded: Bool) {
        guard ticket.generation == generation else { return }
        if succeeded, ticket.revision > confirmedRevision {
            confirmed = ticket.value
            confirmedRevision = ticket.revision
        }
        if pending == ticket.revision { pending = nil }
        if pending == nil { value = confirmed }
    }

    mutating func receive(_ value: Value) {
        guard value != snapshot else { return }
        snapshot = value
        guard pending == nil else { return }
        confirmed = value
        confirmedRevision = revision
        self.value = value
    }

    mutating func reset(_ value: Value) { self = Self(value) }
}

enum PersonalEditIdentity: Hashable {
    case track(Int64), release(Int64)
}

enum PersonalValueLabels {
    static func ratingAfterClick(_ star: UInt8, current: UInt8?) -> UInt8? {
        current == star ? nil : star
    }
    static func rating(_ value: UInt8?) -> String {
        value.map { "\(RatingValues.number(Int($0))) de 5" } ?? "Sem avaliação"
    }
    static func star(_ value: Int) -> String { "\(value) de 5" }
    static func favorite(_ value: Bool) -> String { TrackRowModel.favoriteLabel(value) }
    static func favoriteValue(_ value: Bool) -> String { value ? "Favorita" : "Não favorita" }
}

/// Serializes writes for a property, without delaying its optimistic display.
@MainActor
final class PersonalWriteQueue {
    private struct Entry { let id: UUID; let task: Task<Bool, Never> }
    private var entries: [String: Entry] = [:]

    func waitForPendingWrites() async {
        let pending = entries.values.map(\.task)
        for task in pending { _ = await task.value }
    }

    func perform(key: String, operation: @escaping @MainActor () async -> Bool) async -> Bool {
        let previous = entries[key]?.task
        let id = UUID()
        let task = Task {
            if let previous { _ = await previous.value }
            return await operation()
        }
        entries[key] = Entry(id: id, task: task)
        let result = await task.value
        if entries[key]?.id == id { entries[key] = nil }
        return result
    }
}
