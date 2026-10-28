use crate::{
    api::DownloadFileState,
    application::{music_catalog::IntegrationFuture, music_plugins::PluginContext},
};
#[derive(Clone)]
pub(crate) struct TransferFileSpec {
    pub(crate) filename: String,
    pub(crate) size: u64,
}
#[derive(Clone)]
pub(crate) struct TransferIdentity {
    pub(crate) batch_id: String,
    pub(crate) transfer_id: String,
    pub(crate) file: TransferFileSpec,
}
#[derive(Clone)]
pub(crate) enum TransferAction {
    Enqueue {
        batch_id: String,
        peer: String,
        destination: String,
        files: Vec<TransferFileSpec>,
        previous: Vec<TransferIdentity>,
    },
    Inspect {
        batch_id: String,
        peer: String,
        destination: String,
        files: Vec<TransferFileSpec>,
    },
    Cancel {
        identity: TransferIdentity,
        peer: String,
        destination: String,
    },
}
#[derive(Clone)]
pub(crate) struct TransferCommand {
    pub(crate) endpoint: String,
    pub(crate) action: TransferAction,
}
pub(crate) struct TransferRow {
    pub(crate) transfer_id: String,
    pub(crate) file: TransferFileSpec,
    pub(crate) state: DownloadFileState,
    pub(crate) bytes: u64,
    pub(crate) queue: Option<u32>,
}
pub(crate) struct TransferReceipt {
    pub(crate) not_submitted: Option<crate::domain::music::IntegrationError>,
    pub(crate) rows: Vec<TransferRow>,
}
pub(crate) trait DownloadTransferProvider: Send + Sync {
    fn transfer(
        &self,
        context: PluginContext,
        command: TransferCommand,
    ) -> IntegrationFuture<'_, TransferReceipt>;
}
