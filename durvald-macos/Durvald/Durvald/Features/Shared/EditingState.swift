import Foundation

/// Shared editing lifecycle; domain drafts retain their own validation and mixed-value semantics.
struct EditingState<Value: Equatable> {
    var value: Value
    private(set) var baseline: Value
    private(set) var generation = UUID()
    private var activeSave: UUID?
    private var sourceID: ObjectIdentifier?
    var errorMessage: String?
    private let dirty: (Value, Value) -> Bool

    struct SaveTicket {
        let value: Value
        fileprivate let generation: UUID
        fileprivate let id: UUID
    }

    init(_ value: Value, isDirty: @escaping (Value, Value) -> Bool = { $0 != $1 }) {
        self.value = value
        baseline = value
        dirty = isDirty
    }

    var isDirty: Bool { dirty(value, baseline) }
    var isSaving: Bool { activeSave != nil }
    var snapshot: Value { baseline }

    mutating func receive(_ snapshot: Value) {
        if !isDirty && !isSaving { value = snapshot }
        baseline = snapshot
    }

    mutating func refresh(_ snapshot: Value, sourceID: ObjectIdentifier?) {
        if self.sourceID != sourceID {
            reset(to: snapshot)
            self.sourceID = sourceID
        } else {
            receive(snapshot)
        }
    }

    mutating func reset(to snapshot: Value) {
        generation = UUID()
        activeSave = nil
        errorMessage = nil
        value = snapshot
        baseline = snapshot
    }

    /// Also used for undo, which may start with a clean draft.
    mutating func beginSaving() -> SaveTicket? {
        guard !isSaving else { return nil }
        let id = UUID()
        activeSave = id
        errorMessage = nil
        return SaveTicket(value: value, generation: generation, id: id)
    }

    func isCurrent(_ ticket: SaveTicket) -> Bool {
        generation == ticket.generation && activeSave == ticket.id
    }

    @discardableResult
    mutating func finish(_ ticket: SaveTicket, confirmed: Value) -> Bool {
        guard isCurrent(ticket) else { return false }
        if value == ticket.value { value = confirmed }
        baseline = confirmed
        activeSave = nil
        errorMessage = nil
        return true
    }

    @discardableResult
    mutating func fail(_ ticket: SaveTicket, message: String) -> Bool {
        guard isCurrent(ticket) else { return false }
        activeSave = nil
        errorMessage = message
        return true
    }
}
