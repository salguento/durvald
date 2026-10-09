import SwiftUI
import UniformTypeIdentifiers

struct ArtworkImportPolicy {
    let maximumPixelSize: Int
    let includeOriginalBytes: Bool

    static let trackMetadata = Self(maximumPixelSize: 1024, includeOriginalBytes: false)
    static let playlist = Self(maximumPixelSize: 512, includeOriginalBytes: true)
}

extension View {
    func artworkFileImporter(isPresented: Binding<Bool>, state: ArtworkImportState,
                             policy: ArtworkImportPolicy) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.image], allowsMultipleSelection: false) {
            state.select($0, policy: policy)
        }
    }
}
