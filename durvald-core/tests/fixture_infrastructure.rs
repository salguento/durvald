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
