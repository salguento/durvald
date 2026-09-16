#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIBRARY="${1:-$ROOT/durvald-core/target/aarch64-apple-darwin/release/libdurvald_core.dylib}"
GENERATED="$ROOT/durvald-macos/Durvald/Generated/arm64"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/durvald-ffi.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# Exercise the real async UniFFI boundary without audio, network or Keychain.
# Initialization must fail at the first filesystem operation.
cat > "$TEST_DIR/Smoke.swift" <<'SWIFT'
import Foundation

@main
struct FFISmoke {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("durvald-ffi-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("file-not-directory")
        try Data("probe".utf8).write(to: blocked)
        do {
            _ = try await open(config: CoreConfig(
                databasePath: directory.appendingPathComponent("library.sqlite").path,
                appSupportDir: blocked.path,
                coversDir: directory.appendingPathComponent("covers").path,
                keychainService: "durvald-ffi-probe"))
            fatalError("Expected initialization storage failure")
        } catch CoreError.Storage(let message) {
            precondition(!message.isEmpty)
            print("UniFFI async/config/error/checksum smoke passed")
        }
    }
}
SWIFT

swiftc -swift-version 5 -parse-as-library \
    -module-cache-path "$TEST_DIR/modules" \
    -Xcc "-fmodule-map-file=$GENERATED/durvald_coreFFI.modulemap" \
    -I "$GENERATED" -L "$(dirname "$LIBRARY")" -ldurvald_core \
    -Xlinker -rpath -Xlinker "$(dirname "$LIBRARY")" \
    "$GENERATED/durvald_core.swift" "$TEST_DIR/Smoke.swift" -o "$TEST_DIR/smoke"
"$TEST_DIR/smoke"
