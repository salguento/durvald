use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

use super::filesystem::TestFs;

fn validate_fixture_path(path: &Path) -> io::Result<()> {
    if path.as_os_str().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "fixture path must not be empty",
        ));
    }

    for component in path.components() {
        match component {
            Component::Normal(_) | Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "fixture path must stay inside the fixtures directory",
                ));
            }
        }
    }

    Ok(())
}

pub fn fixture_path(relative_path: impl AsRef<Path>) -> io::Result<PathBuf> {
    let relative_path = relative_path.as_ref();

    validate_fixture_path(relative_path)?;

    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(relative_path);

    if !path.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!("fixture does not exist: {}", path.display()),
        ));
    }

    Ok(path)
}

impl TestFs {
    pub fn copy_fixture_to_library(
        &self,
        fixture: impl AsRef<Path>,
        destination: impl AsRef<Path>,
    ) -> io::Result<PathBuf> {
        let source = fixture_path(fixture)?;
        let contents = fs::read(source)?;

        self.write_library_file(destination, &contents)
    }
}
