import Foundation

/// Shared numeric rules; batch callers still decide which fields are enabled or mixed.
enum MetadataDraftValidation {
    static func number(_ text: String, name: String, maximum: UInt32) throws -> UInt32? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let value = UInt32(text), value <= maximum, name != "Ano" || value > 0 else {
            throw TrackMetadataDraft.DraftError.invalid("\(name): informe um número válido até \(maximum).")
        }
        return value
    }
}
