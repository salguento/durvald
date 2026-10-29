import XCTest
@testable import Durvald

@MainActor
final class IntegrationDiagnosticsTests: XCTestCase {
    func testRecoveryMessagesExplainTimeoutCredentialsAndLocalAvailability() {
        XCTAssertTrue(IntegrationOutcome.timedOut.recoveryMessage.contains("rede"))
        XCTAssertTrue(IntegrationOutcome.authentication.recoveryMessage.contains("credencial"))
        XCTAssertTrue(IntegrationOutcome.unavailable.recoveryMessage.contains("biblioteca local"))
        XCTAssertTrue(IntegrationOutcome.rateLimited.recoveryMessage.contains("Aguarde"))
        XCTAssertEqual(IntegrationOperation.playbackResolution.diagnosticLabel, "Preparação da fonte")
    }
    func testDiagnosticsFFIReadsCountersWithoutNetworkOrEnablingOptionalIntegrations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try await open(config: CoreConfig(databasePath: root.appendingPathComponent("library.sqlite").path, appSupportDir: root.path, coversDir: root.appendingPathComponent("covers").path, keychainService: "diagnostics-ffi-\(UUID())"))
        let first = await core.integrationDiagnostics()
        let second = await core.integrationDiagnostics()
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.preferencesAvailable)
        XCTAssertEqual(first.providers.count, 8)
        XCTAssertTrue(first.providers.allSatisfy { $0.measurements.isEmpty })
        XCTAssertEqual(first.providers.first { $0.provider == "youtube" }?.enabled, false)
        XCTAssertEqual(first.providers.first { $0.provider == "slskd" }?.enabled, false)
    }
}
