/// Mirrors `first(where:)`: duplicate identifiers retain the first record,
/// including records without artwork or duration.
func firstRecordIndex<Record, Key: Hashable>(_ records: [Record], key: (Record) -> Key?) -> [Key: Record] {
    var result: [Key: Record] = [:]
    for record in records {
        guard let id = key(record), result[id] == nil else { continue }
        result[id] = record
    }
    return result
}

