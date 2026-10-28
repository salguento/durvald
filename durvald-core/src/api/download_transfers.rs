//! Persistent acquisition jobs. Backend paths never become local media sources.
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DownloadTransferSettings {
    pub enabled: bool,
    pub remote_download_root: String,
    pub mapped_download_root: String,
    pub library_destination: String,
    pub mapping_confirmed: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum DownloadFileState {
    Prepared,
    SubmissionUnknown,
    Queued,
    Downloading,
    Completed,
    Failed,
    Cancelled,
    Importing,
    Imported,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DownloadTransferFile {
    pub index: u32,
    pub filename: String,
    pub size_bytes: u64,
    pub bytes_transferred: u64,
    pub state: DownloadFileState,
    pub queue_position: Option<u32>,
    pub imported_track_id: Option<i64>,
    pub imported_path: Option<String>,
    pub message: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DownloadTransferJob {
    pub job_id: String,
    pub peer: String,
    pub folder: String,
    pub created_at: i64,
    pub relative_destination: String,
    pub remote_download_root: String,
    pub mapped_download_root: String,
    pub library_destination: String,
    pub files: Vec<DownloadTransferFile>,
    pub cancel_requested: bool,
    pub message: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct DownloadImportPreview {
    pub target_track_id: Option<i64>,
    pub resuming: bool,
    pub review_token: String,
    pub job_id: String,
    pub file_index: u32,
    pub title: String,
    pub artist: String,
    pub release: String,
    pub duration_seconds: f64,
    pub size_bytes: u64,
    pub destination: String,
}
