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
