#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="$ROOT/durvald-core"
OUT="$ROOT/durvald-macos/Durvald/Generated/arm64"
TARGET="aarch64-apple-darwin"

mkdir -p "$OUT"
cargo build --manifest-path "$CORE/Cargo.toml" --features uniffi --release --target "$TARGET"
cd "$CORE"
cargo run --features uniffi --bin uniffi-bindgen -- generate --library "target/$TARGET/release/libdurvald_core.dylib" --language swift --out-dir "$OUT"
