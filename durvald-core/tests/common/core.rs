use durvald_core::CoreConfig;
#[cfg(feature = "test-support")]
use std::error::Error;

#[cfg(feature = "test-support")]
use std::sync::{Arc, OnceLock};

#[cfg(feature = "test-support")]
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

#[cfg(feature = "test-support")]
use durvald_core::DurvaldCore;

use super::filesystem::TestFs;

#[cfg(feature = "test-support")]
static TEST_CORE_LIMIT: OnceLock<Arc<Semaphore>> = OnceLock::new();

#[cfg(feature = "test-support")]
fn test_core_limit() -> Arc<Semaphore> {
    TEST_CORE_LIMIT
        .get_or_init(|| Arc::new(Semaphore::new(4)))
        .clone()
}

#[cfg(feature = "test-support")]
pub struct TestCore {
    core: Arc<DurvaldCore>,
    files: TestFs,
    _permit: OwnedSemaphorePermit,
}

#[cfg(feature = "test-support")]
impl TestCore {
    pub async fn open() -> Result<Self, Box<dyn Error + Send + Sync>> {
        let files = TestFs::new()?;

        Self::open_with_files(files).await
    }

    pub async fn open_with_files(files: TestFs) -> Result<Self, Box<dyn Error + Send + Sync>> {
        let permit = test_core_limit().acquire_owned().await?;

        let config = files.core_config();

        let core = durvald_core::test_support::open_core(config).await?;

        Ok(Self {
            core,
            files,
            _permit: permit,
        })
    }

    pub fn core(&self) -> &Arc<DurvaldCore> {
        &self.core
    }

    pub fn files(&self) -> &TestFs {
        &self.files
    }

    pub async fn restart(self) -> Result<Self, Box<dyn Error + Send + Sync>> {
        let Self {
            core,
            files,
            _permit,
        } = self;

        drop(core);

        let config = files.core_config();

        let core = durvald_core::test_support::open_core(config).await?;

        Ok(Self {
            core,
            files,
            _permit,
        })
    }

    pub async fn process_mock_audio(&self, blocks: usize) {
        durvald_core::test_support::process_mock_audio(self.core.as_ref(), blocks).await;
    }
}

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
