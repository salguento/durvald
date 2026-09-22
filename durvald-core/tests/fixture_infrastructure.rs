mod common;

use std::io;

use common::{TestFs, fixture_path};

#[test]
fn creates_expected_directory_tree() -> io::Result<()> {
    let files = TestFs::new()?;

    assert!(files.root().exists());
    assert!(files.app_support_dir().exists());
    assert!(files.covers_dir().exists());
    assert!(files.library_dir().exists());
    assert!(!files.database_path().exists());

    Ok(())
}

#[test]
fn writes_file_inside_temporary_library() -> io::Result<()> {
    let files = TestFs::new()?;

    let created = files.write_library_file("Artist/Album/01.flac", b"fake audio")?;

    assert!(files.library_dir().join("Artist/Album").is_dir());
    assert!(created.exists());
    assert!(created.starts_with(files.library_dir()));
    assert_eq!(std::fs::read(created)?, b"fake audio");

    Ok(())
}

#[test]
fn rejects_path_that_escapes_temporary_library() -> io::Result<()> {
    let files = TestFs::new()?;

    let result = files.write_library_file("../../outside.txt", b"must not be written");

    assert!(result.is_err());

    Ok(())
}

#[test]
fn rejects_absolute_library_path() -> io::Result<()> {
    let files = TestFs::new()?;

    let absolute_path = std::env::temp_dir().join("outside-durvald-test.txt");

    let result = files.write_library_file(absolute_path, b"must not be written");

    assert!(result.is_err());

    Ok(())
}

#[test]
fn test_environments_do_not_share_state() -> io::Result<()> {
    let first = TestFs::new()?;
    let second = TestFs::new()?;

    let first_file = first.write_library_file("Artist/Album/01.flac", b"first")?;

    let equivalent_second_path = second.library_dir().join("Artist/Album/01.flac");

    assert_ne!(first.root(), second.root());
    assert!(first_file.exists());
    assert!(!equivalent_second_path.exists());

    Ok(())
}

#[test]
fn resolves_versioned_fixture() -> io::Result<()> {
    let path = fixture_path("musicbrainz-homonyms.json")?;

    assert!(path.is_file());
    assert!(path.ends_with("tests/fixtures/musicbrainz-homonyms.json"));

    Ok(())
}

#[test]
fn reports_missing_fixture() {
    let result = fixture_path("does-not-exist.json");

    assert!(result.is_err());

    let error = result.unwrap_err();

    assert_eq!(error.kind(), io::ErrorKind::NotFound);
}

#[test]
fn rejects_fixture_path_outside_fixture_directory() {
    let result = fixture_path("../../Cargo.toml");

    assert!(result.is_err());

    let error = result.unwrap_err();

    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
}

#[test]
fn copies_fixture_to_temporary_library() -> io::Result<()> {
    let files = TestFs::new()?;

    let copied = files.copy_fixture_to_library(
        "musicbrainz-homonyms.json",
        "network/musicbrainz-homonyms.json",
    )?;

    let original = fixture_path("musicbrainz-homonyms.json")?;

    assert!(copied.exists());
    assert!(copied.starts_with(files.library_dir()));
    assert_eq!(std::fs::read(copied)?, std::fs::read(original)?,);

    Ok(())
}

#[test]
fn changing_fixture_copy_does_not_change_original() -> io::Result<()> {
    let files = TestFs::new()?;

    let original = fixture_path("musicbrainz-homonyms.json")?;
    let original_contents = std::fs::read(&original)?;

    let copied = files.copy_fixture_to_library(
        "musicbrainz-homonyms.json",
        "mutable/musicbrainz-homonyms.json",
    )?;

    std::fs::write(&copied, b"changed temporary copy")?;

    assert_eq!(std::fs::read(&original)?, original_contents,);

    assert_ne!(std::fs::read(&copied)?, original_contents,);

    Ok(())
}

#[test]
fn rejects_fixture_copy_outside_temporary_library() -> io::Result<()> {
    let files = TestFs::new()?;

    let result = files.copy_fixture_to_library("musicbrainz-homonyms.json", "../../outside.json");

    assert!(result.is_err());

    Ok(())
}

#[test]
fn builds_core_config_from_temporary_paths() -> io::Result<()> {
    let files = TestFs::new()?;
    let config = files.core_config();

    assert_eq!(
        config.database_path,
        files.database_path().to_string_lossy(),
    );

    assert_eq!(
        config.app_support_dir,
        files.app_support_dir().to_string_lossy(),
    );

    assert_eq!(config.covers_dir, files.covers_dir().to_string_lossy(),);

    assert!(config.keychain_service.starts_with("durvald-test-"));

    Ok(())
}

#[test]
fn core_configs_use_distinct_keychain_services() -> io::Result<()> {
    let first = TestFs::new()?;
    let second = TestFs::new()?;

    let first_config = first.core_config();
    let second_config = second.core_config();

    assert_ne!(first_config.database_path, second_config.database_path,);

    assert_ne!(
        first_config.keychain_service,
        second_config.keychain_service,
    );

    Ok(())
}

#[test]
fn removes_file_from_temporary_library() -> io::Result<()> {
    let files = TestFs::new()?;

    let created = files.write_library_file("Artist/Album/remove-me.txt", b"temporary")?;

    assert!(created.is_file());

    files.remove_library_file("Artist/Album/remove-me.txt")?;

    assert!(!created.exists());

    Ok(())
}

#[test]
fn rejects_removal_outside_temporary_library() -> io::Result<()> {
    let files = TestFs::new()?;

    let result = files.remove_library_file("../../outside.txt");

    assert!(result.is_err());

    Ok(())
}
