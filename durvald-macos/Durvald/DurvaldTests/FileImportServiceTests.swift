import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Durvald

@MainActor
final class FileImportServiceTests: XCTestCase {
    func testArtworkReadRunsOffMainThreadWithBoundedPreviewAndOriginalBytes() async throws {
        let bytes = try imageBytes()
        let probe = ImportAccessProbe()
        let service = service(probe: probe) { _ in bytes }
        let result = try await service.artwork(from: URL(fileURLWithPath: "/fake/image.png"), maximumPixelSize: 64, includeOriginalBytes: true)
        XCTAssertEqual(max(result.preview.width, result.preview.height), 64)
        XCTAssertEqual(result.preview.width, result.preview.height * 2)
        XCTAssertEqual(Data(base64Encoded: result.originalBase64!), bytes)
        XCTAssertEqual(probe.events, ["start", "read", "stop"])
        XCTAssertFalse(probe.usedMainThread)
    }

    func testDecodeAndReadErrorsReleaseSecurityScope() async {
        for readFails in [true, false] {
            let probe = ImportAccessProbe()
            let service = service(probe: probe) { _ in
                if readFails { throw CocoaError(.fileReadNoPermission) }
                return Data("not an image".utf8)
            }
            do {
                _ = try await service.artwork(from: URL(fileURLWithPath: "/fake/image.png"), maximumPixelSize: 64, includeOriginalBytes: false)
                XCTFail("Expected import error")
            } catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertEqual(probe.events, ["start", "read", "stop"])
        }
    }

    func testOrdinaryFileWithoutSecurityScopeStillReadsWithoutUnbalancedStop() async throws {
        let bytes = try imageBytes()
        let probe = ImportAccessProbe()
        let service = service(probe: probe, acquiresScope: false) { _ in bytes }
        let result = try await service.artwork(from: URL(fileURLWithPath: "/fake/image.png"), maximumPixelSize: 32, includeOriginalBytes: false)
        XCTAssertNil(result.originalBase64)
        XCTAssertEqual(probe.events, ["start", "read"])
    }

    func testCancellationKeepsScopeOpenUntilBlockedReadFinishes() async throws {
        let bytes = try imageBytes()
        let probe = ImportAccessProbe()
        let started = expectation(description: "Read started")
        let release = DispatchSemaphore(value: 0)
        let service = service(probe: probe) { _ in
            started.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
            return bytes
        }
        let task = Task { try await service.artwork(from: URL(fileURLWithPath: "/fake/image.png"), maximumPixelSize: 32, includeOriginalBytes: true) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        XCTAssertEqual(probe.events, ["start", "read"])
        release.signal()
        do { _ = try await task.value; XCTFail("Cancelled read published a result") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(probe.events, ["start", "read", "stop"])
    }

    func testExistingArtworkAcceptsBase64AndDataURLAndRejectsCorruption() async throws {
        let bytes = try imageBytes()
        let base64 = bytes.base64EncodedString()
        for value in [base64, "data:image/png;base64," + base64] {
            let result = try await FileImportService.shared.artwork(base64: value, maximumPixelSize: 64)
            XCTAssertEqual(max(result.preview.width, result.preview.height), 64)
            XCTAssertEqual(result.originalBase64, value)
        }
        do {
            _ = try await FileImportService.shared.artwork(base64: "invalid", maximumPixelSize: 64)
            XCTFail("Expected invalid base64 to fail")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testPlaylistReadPreservesRelativePathsOrderAndDuplicates() async throws {
        let probe = ImportAccessProbe()
        let service = service(probe: probe) { _ in Data("\u{FEFF}#EXTM3U\ntrack.flac\n../other.flac\ntrack.flac\n".utf8) }
        let paths = try await service.playlistPaths(from: URL(fileURLWithPath: "/tmp/collection/list.m3u8"))
        XCTAssertEqual(paths.map(\.url.path), ["/tmp/collection/track.flac", "/tmp/other.flac", "/tmp/collection/track.flac"])
        XCTAssertEqual(paths[0].canonicalPath, paths[2].canonicalPath)
        XCTAssertEqual(probe.events, ["start", "read", "stop"])
        XCTAssertFalse(probe.usedMainThread)
    }

    func testInvalidPlaylistClosesScopeAndPreservesParseErrors() async {
        for data in [Data([0xFF]), Data("#EXTM3U\n".utf8)] {
            let probe = ImportAccessProbe()
            let service = service(probe: probe) { _ in data }
            do { _ = try await service.playlistPaths(from: URL(fileURLWithPath: "/tmp/list.m3u8")); XCTFail("Expected parse error") }
            catch { XCTAssertTrue(error is PlaylistTransferError) }
            XCTAssertEqual(probe.events, ["start", "read", "stop"])
        }
    }

    func testPathIndexResolvesSymlinksAndKeepsFirstCatalogMatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.flac")
        let link = directory.appendingPathComponent("alias.flac")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let index = try await FileImportService.shared.pathIndex([link.path, target.path])
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index[PlaylistTransferService.canonicalPath(target)], 0)
    }

    func testNewArtworkSelectionDiscardsLateResultAndCancelPreventsPublication() async throws {
        let state = ArtworkImportState()
        let image = try preview()
        let gate = ImportArtworkGate()
        let old = state.start { await gate.load() }
        await gate.waitUntilStarted()
        let latest = state.start { ImportedArtwork(preview: image.preview, originalBase64: "latest") }
        await latest.value
        await gate.resume(image)
        await old.value
        XCTAssertEqual(state.originalBase64, "latest")
        XCTAssertEqual(state.revision, 1)
        let nextGate = ImportArtworkGate()
        let cancelled = state.start { await nextGate.load() }
        await nextGate.waitUntilStarted()
        state.cancel()
        await nextGate.resume(image)
        await cancelled.value
        XCTAssertEqual(state.originalBase64, "latest")
        XCTAssertEqual(state.revision, 1)
        XCTAssertFalse(state.isLoading)
    }

    private func service(probe: ImportAccessProbe, acquiresScope: Bool = true,
                         read: @escaping @Sendable (URL) throws -> Data) -> FileImportService {
        FileImportService(access: ScopedImportFileAccess(
            start: { _ in probe.record("start"); return acquiresScope },
            stop: { _ in probe.record("stop") },
            read: { url in probe.record("read"); return try read(url) }
        ))
    }

    private func preview() throws -> ImportedArtwork {
        let bytes = try imageBytes()
        let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
        return ImportedArtwork(preview: CGImageSourceCreateImageAtIndex(source, 0, nil)!, originalBase64: "old")
    }

    private func imageBytes() throws -> Data {
        let context = CGContext(data: nil, width: 512, height: 256, bitsPerComponent: 8, bytesPerRow: 512 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}

private final class ImportAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var mainThread = false
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recordedEvents }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    func record(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        recordedEvents.append(event)
        mainThread = mainThread || Thread.isMainThread
    }
}

private actor ImportArtworkGate {
    private var result: CheckedContinuation<ImportedArtwork, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func load() async -> ImportedArtwork {
        await withCheckedContinuation { continuation in
            result = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume(_ artwork: ImportedArtwork) { result?.resume(returning: artwork); result = nil }
}
