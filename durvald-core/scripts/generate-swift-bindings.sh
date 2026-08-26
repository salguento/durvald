#!/usr/bin/env bash
set -euo pipefail

# Generates Swift bindings with the UniFFI version pinned by durvald-core.
# UniFFI 0.27 emits a direct Swift function reference that recent Swift
# compilers reject for a C callback. Normalize that one generated call into a
# C-compatible literal closure after each generation.

root_dir="$(cd "$(dirname "$0")/../.." && pwd)"
crate_dir="$root_dir/durvald-core"
target="${1:-aarch64-apple-darwin}"
output_dir="${2:-$root_dir/durvald-macos/Durvald/Generated/arm64}"

mkdir -p "$output_dir"
cargo build --manifest-path "$crate_dir/Cargo.toml" --features uniffi --release --target "$target"

frameworks_dir="$root_dir/durvald-macos/Durvald/Frameworks"
mkdir -p "$frameworks_dir"
cp "$crate_dir/target/$target/release/libdurvald_core.dylib" "$frameworks_dir/libdurvald_core.dylib"

cd "$crate_dir"
cargo run --features uniffi --bin uniffi-bindgen -- generate --library "target/$target/release/libdurvald_core.dylib" --language swift --out-dir "$output_dir"

temporary_binding="$(mktemp /private/tmp/durvald-core-swift-binding.XXXXXX)"
awk '
    /^[[:space:]]*uniffiFutureContinuationCallback,/ {
        indent = $0
        sub(/[^[:space:]].*$/, "", indent)
        print indent "{ handle, pollResult in"
        print indent "    uniffiFutureContinuationCallback(handle: handle, pollResult: pollResult)"
        print indent "},"
        next
    }
    { print }
' "$output_dir/durvald_core.swift" > "$temporary_binding"
mv "$temporary_binding" "$output_dir/durvald_core.swift"

# The Xcode app source directory is file-system synchronized, so copy the
# generated wrapper there after applying the compatibility patch. The C header
# and module map remain in Generated/arm64 and are imported via the bridging
# header configured in Xcode.
app_binding="$root_dir/durvald-macos/Durvald/Durvald/durvald_core.swift"
if [[ -d "$(dirname "$app_binding")" ]]; then
    cp "$output_dir/durvald_core.swift" "$app_binding"
fi
