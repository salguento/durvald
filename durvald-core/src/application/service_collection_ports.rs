use crate::{
    api::*,
    application::{music_catalog::IntegrationFuture, music_plugins::PluginContext},
};
#[derive(Clone)]
pub(crate) struct ServicePageRequest {
    pub(crate) url: String,
    pub(crate) cursor: Option<String>,
}
#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct ServicePage {
    pub(crate) title: String,
    pub(crate) is_collection: bool,
    pub(crate) items: Vec<ServiceCollectionItem>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) truncated: bool,
}
pub(crate) trait ServiceCollectionReader: Send + Sync {
    fn read(
        &self,
        context: PluginContext,
        request: ServicePageRequest,
    ) -> IntegrationFuture<'_, ServicePage>;
}
