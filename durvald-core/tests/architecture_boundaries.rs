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

fn rust_files(directory: &Path) -> Vec<std::path::PathBuf> {
    let mut files = Vec::new();
    for entry in fs::read_dir(directory).expect("source directory must be readable") {
        let path = entry.expect("source entry must be readable").path();
        if path.is_dir() {
            files.extend(rust_files(&path));
        } else if path.extension().and_then(|extension| extension.to_str()) == Some("rs") {
            files.push(path);
        }
    }
    files
}

#[test]
fn application_layer_does_not_reference_database_internals() {
    let application_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/application");
    let mut violations = Vec::new();

    for path in rust_files(&application_dir) {
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
fn facade_does_not_bypass_application_with_database_operations() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/core.rs");
    let source = fs::read_to_string(root).unwrap();
    // The final test module legitimately prepares database fixtures. All facade
    // implementations and test-only helper functions above it remain checked.
    let (facade, _) = source
        .split_once("#[cfg(test)]\nmod tests {")
        .expect("core fixture module boundary must remain explicit");
    for dependency in FORBIDDEN_APPLICATION_DEPENDENCIES {
        assert!(
            !facade.contains(dependency),
            "facade references {dependency}"
        );
    }
    assert!(!source.contains("personal_library_operation"));
}

#[test]
fn playlist_rules_are_independent_from_storage() {
    for name in ["replay.rs", "smart_playlist.rs"] {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("src/domain")
            .join(name);
        let source = fs::read_to_string(path).unwrap();
        for dependency in FORBIDDEN_APPLICATION_DEPENDENCIES
            .iter()
            .copied()
            .chain(["crate::infrastructure", "crate::application"])
        {
            assert!(
                !source.contains(dependency),
                "{name} references {dependency}"
            );
        }
    }
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

#[test]
fn music_contracts_do_not_depend_on_storage_transport_or_public_dtos() {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("src/domain/music");
    for entry in fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|extension| extension.to_str()) != Some("rs") {
            continue;
        }
        let source = fs::read_to_string(&path).unwrap();
        for dependency in [
            "crate::api",
            "crate::database",
            "crate::infrastructure",
            "crate::application",
            "reqwest::",
            "rusqlite",
            "uniffi::",
        ] {
            assert!(
                !source.contains(dependency),
                "{} references {dependency}",
                path.display()
            );
        }
    }
}
