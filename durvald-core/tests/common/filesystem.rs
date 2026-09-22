use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};
use tempfile::TempDir;

pub struct TestFs {
    root: TempDir,
    app_support_dir: PathBuf,
    covers_dir: PathBuf,
    library_dir: PathBuf,
    database_path: PathBuf,
}

fn validate_relative_path(path: &Path) -> io::Result<()> {
    if path.as_os_str().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "path must not be empty",
        ));
    }

    for component in path.components() {
        match component {
            Component::Normal(_) => {}
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "path must stay inside the test directory",
                ));
            }
        }
    }

    Ok(())
}

impl TestFs {
    pub fn new() -> io::Result<Self> {
        let root = tempfile::tempdir()?;
        let app_support_dir = root.path().join("app-support");
        let covers_dir = root.path().join("covers");
        let library_dir = root.path().join("library");
        let database_path = root.path().join("durvald.sqlite");

        fs::create_dir_all(&app_support_dir)?;
        fs::create_dir_all(&covers_dir)?;
        fs::create_dir_all(&library_dir)?;

        Ok(Self {
            root,
            app_support_dir,
            covers_dir,
            library_dir,
            database_path,
        })
    }

    pub fn write_library_file(
        &self,
        relative_path: impl AsRef<Path>,
        contents: &[u8],
    ) -> io::Result<PathBuf> {
        let relative_path = relative_path.as_ref();

        validate_relative_path(relative_path)?;

        let destination = self.library_dir.join(relative_path);

        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }

        fs::write(&destination, contents)?;

        Ok(destination)
    }

    pub fn remove_library_file(&self, relative_path: impl AsRef<Path>) -> io::Result<()> {
        let relative_path = relative_path.as_ref();

        validate_relative_path(relative_path)?;

        let path = self.library_dir.join(relative_path);

        fs::remove_file(path)
    }

    pub fn root(&self) -> &Path {
        self.root.path()
    }

    pub fn library_dir(&self) -> &Path {
        &self.library_dir
    }

    pub fn app_support_dir(&self) -> &Path {
        &self.app_support_dir
    }

    pub fn covers_dir(&self) -> &Path {
        &self.covers_dir
    }

    pub fn database_path(&self) -> &Path {
        &self.database_path
    }
}
