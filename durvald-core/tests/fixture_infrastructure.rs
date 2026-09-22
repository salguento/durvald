mod common;

use std::io;

use common::TestFs;

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
