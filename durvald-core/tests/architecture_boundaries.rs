use std::{fs, path::Path};

const FORBIDDEN_APPLICATION_DEPENDENCIES: &[&str] = &[
    "crate::database",
    "database::operations",
    "database::models",
    "rusqlite",
    "r2d2",
    "SqliteConnectionManager",
    "DatabasePool",
];

const DELIBERATE_PUBLIC_MODULES: &[&str] = &["api", "test_support"];

#[test]
fn application_layer_does_not_reference_database_internals() {
    let application_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/application");
    let mut violations = Vec::new();

    for entry in fs::read_dir(&application_dir).expect("application directory must be readable") {
        let path = entry.expect("application entry must be readable").path();
        if path.extension().and_then(|extension| extension.to_str()) != Some("rs") {
            continue;
        }

        let source = fs::read_to_string(&path).expect("application source must be readable");
        for dependency in FORBIDDEN_APPLICATION_DEPENDENCIES {
            if source.contains(dependency) {
                violations.push(format!("{} references {dependency}", path.display()));
            }
        }
    }

    assert!(
        violations.is_empty(),
        "application must stay independent from database internals:\n{}",
        violations.join("\n")
    );
}

#[test]
fn crate_root_exposes_only_deliberate_public_modules() {
    let crate_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/lib.rs");
    let source = fs::read_to_string(&crate_root).expect("crate root must be readable");
    let public_modules = source
        .lines()
        .filter_map(|line| {
            line.trim()
                .strip_prefix("pub mod ")
                .and_then(|module| module.strip_suffix(';'))
        })
        .collect::<Vec<_>>();

    assert_eq!(
        public_modules, DELIBERATE_PUBLIC_MODULES,
        "new public modules must be deliberate API decisions; keep implementation modules private"
    );
}
