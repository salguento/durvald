use durvald_core::CoreConfig;
#[cfg(feature = "test-support")]
use std::error::Error;

#[cfg(feature = "test-support")]
use std::sync::Arc;

#[cfg(feature = "test-support")]
use durvald_core::DurvaldCore;

use super::filesystem::TestFs;

impl TestFs {
    pub fn core_config(&self) -> CoreConfig {
        CoreConfig {
            database_path: self.database_path().to_string_lossy().into_owned(),
            app_support_dir: self.app_support_dir().to_string_lossy().into_owned(),
            covers_dir: self.covers_dir().to_string_lossy().into_owned(),
            keychain_service: self.test_keychain_service(),
        }
    }

    fn test_keychain_service(&self) -> String {
        let directory_name = self
            .root()
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("unknown");

        format!("durvald-test-{directory_name}")
    }
}

#[cfg(feature = "test-support")]
pub struct TestCore {
    core: Arc<DurvaldCore>,
    files: TestFs,
}

#[cfg(feature = "test-support")]
impl TestCore {
    pub async fn open() -> Result<Self, Box<dyn Error + Send + Sync>> {
        let files = TestFs::new()?;

        Self::open_with_files(files).await
    }

    pub async fn open_with_files(files: TestFs) -> Result<Self, Box<dyn Error + Send + Sync>> {
        let config = files.core_config();

        let core = durvald_core::test_support::open_core(config).await?;

        Ok(Self { core, files })
    }

    pub fn core(&self) -> &Arc<DurvaldCore> {
        &self.core
    }

    pub fn files(&self) -> &TestFs {
        &self.files
    }

    pub async fn restart(self) -> Result<Self, Box<dyn Error + Send + Sync>> {
        let Self { core, files } = self;

        drop(core);

        let config = files.core_config();
        let core = durvald_core::test_support::open_core(config).await?;

        Ok(Self { core, files })
    }
}
