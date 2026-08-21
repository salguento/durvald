//! Project-local UniFFI binding generator.
//!
//! Keeping this binary in the crate guarantees that generated bindings use the
//! exact UniFFI version pinned by `durvald-core`, avoiding metadata-version
//! mismatches from a globally installed `uniffi-bindgen`.

#[cfg(feature = "uniffi")]
fn main() {
    uniffi::uniffi_bindgen_main();
}

#[cfg(not(feature = "uniffi"))]
fn main() {
    eprintln!("Run with `cargo run --features uniffi --bin uniffi-bindgen -- ...`");
    std::process::exit(2);
}
