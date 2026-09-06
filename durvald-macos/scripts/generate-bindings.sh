#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="$ROOT/durvald-core"
OUT="$ROOT/durvald-macos/Durvald/Generated/arm64"
FRAMEWORKS="$ROOT/durvald-macos/Durvald/Frameworks"
TARGET="aarch64-apple-darwin"
LIBRARY="$CORE/target/$TARGET/release/libdurvald_core.dylib"
EMBEDDED_LIBRARY="$FRAMEWORKS/libdurvald_core.dylib"

mkdir -p "$OUT" "$FRAMEWORKS"
cargo build --manifest-path "$CORE/Cargo.toml" --features uniffi --release --target "$TARGET"

# Cargo gives cdylibs an absolute install name derived from target/. Xcode then
# records that development-machine path in the app, even though the library is
# embedded in the bundle. Use an rpath-relative identity before linking/copying.
install_name_tool -id "@rpath/libdurvald_core.dylib" "$LIBRARY"
cp "$LIBRARY" "$EMBEDDED_LIBRARY"

cd "$CORE"
cargo run --features uniffi --bin uniffi-bindgen -- generate --library "$LIBRARY" --language swift --out-dir "$OUT"
