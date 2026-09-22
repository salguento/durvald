use durvald_core::CoreConfig;

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
