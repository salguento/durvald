// build.rs - rerun when the UDL contract changes (used by uniffi-bindgen, not include_scaffolding).
fn main() {
    println!("cargo:rerun-if-changed=src/durvald.udl");
}
