import Foundation

/// Managed paths/IDs remain resolved by the core; inline images use content identity.
enum ArtworkSource: Equatable, Sendable {
    case managed(String)
    case base64(String)
}
