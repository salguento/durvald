use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use tempfile::TempDir;

pub struct TestFs {
    root: TempDir,
    app_support_dir: PathBuf,
    covers_dir: PathBuf,
    library_dir: PathBuf,
    database_path: PathBuf,
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
