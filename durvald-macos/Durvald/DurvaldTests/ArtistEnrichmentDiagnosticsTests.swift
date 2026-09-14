import XCTest
@testable import Durvald

final class ArtistEnrichmentDiagnosticsTests: XCTestCase {
    func testDatabaseBusyMessagePreservesCacheContext() {
        let result = ArtistRefreshSectionResult(
            section: .discography,
            status: .unavailable,
            retryAfterSeconds: nil,
            coverProgress: nil,
            diagnostic: .databaseBusy,
            provider: .musicBrainz
        )

        XCTAssertEqual(
            ArtistEnrichmentDiagnostics.message(for: result, hasCachedContent: true),
            "Banco ocupado; nova tentativa pode ser feita agora. O conteúdo do cache local foi preservado."
        )
        XCTAssertTrue(ArtistEnrichmentDiagnostics.isRetryable(result))
    }

    func testCoverArtArchiveFailureIsSectionSpecific() {
        let result = ArtistRefreshSectionResult(
            section: .covers,
            status: .unavailable,
            retryAfterSeconds: nil,
            coverProgress: nil,
            diagnostic: .providerUnavailable,
            provider: .coverArtArchive
        )

        XCTAssertEqual(
            ArtistEnrichmentDiagnostics.message(for: result, hasCachedContent: false),
            "Cover Art Archive indisponível."
        )
    }

    func testOnlyActionableStatusesAreRetryable() {
        let make: (ArtistRefreshStatus) -> ArtistRefreshSectionResult = { status in
            ArtistRefreshSectionResult(
                section: .profile,
                status: status,
                retryAfterSeconds: nil,
                coverProgress: nil,
                diagnostic: nil,
                provider: .wikidata
            )
        }

        XCTAssertTrue(ArtistEnrichmentDiagnostics.isRetryable(make(.partial)))
        XCTAssertTrue(ArtistEnrichmentDiagnostics.isRetryable(make(.rateLimited)))
        XCTAssertTrue(ArtistEnrichmentDiagnostics.isRetryable(make(.unavailable)))
        XCTAssertFalse(ArtistEnrichmentDiagnostics.isRetryable(make(.offline)))
        XCTAssertFalse(ArtistEnrichmentDiagnostics.isRetryable(make(.notFound)))
        XCTAssertFalse(ArtistEnrichmentDiagnostics.isRetryable(make(.needsIdentity)))
    }
}
