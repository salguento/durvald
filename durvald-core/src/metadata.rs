//! Metadata extraction module using lofty

use base64::engine::general_purpose::STANDARD;
use base64::Engine as _;
use image;
use lofty::file::AudioFile;
use lofty::file::TaggedFileExt;
use lofty::read_from_path;
use lofty::tag::Accessor;
use md5::{Digest, Md5};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum MetadataError {
    #[error("Lofty error: {0}")]
    Lofty(#[from] lofty::error::LoftyError),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Base64 error: {0}")]
    Base64(#[from] base64::DecodeError),
    #[error("Image error: {0}")]
    Image(#[from] image::ImageError),
    #[error("{0}")]
    Custom(String),
}

pub type MetadataResult<T> = Result<T, MetadataError>;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct AudioMetadata {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub release: Option<String>,
    pub genre: Option<String>,
    pub year: Option<u32>,
    pub track: Option<u32>,
    pub disc: Option<u32>,
    pub duration: f64,
    pub bitrate: Option<u32>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u8>,
    /// Legacy: embedded base64 data URL. Kept so already-persisted rows and
    /// the FolderSelector preview keep working unchanged.
    pub cover_image_base64: Option<String>,
    /// New: absolute path of the cover file, served via the asset protocol.
    /// Empty only when the track has no embedded artwork.
    pub cover_path: Option<String>,
    pub all_fields: HashMap<String, String>,
    pub file_path: String,
}

/// Extracts the front cover (or first embedded picture) as `(mime, raw bytes)`.
fn extract_cover_bytes(tag: &lofty::tag::Tag) -> Option<(String, Vec<u8>)> {
    let picture = tag
        .get_picture_type(lofty::picture::PictureType::CoverFront)
        .or_else(|| tag.pictures().first())?;

    let mime = match picture.mime_type() {
        Some(lofty::picture::MimeType::Jpeg) => "image/jpeg".to_string(),
        Some(lofty::picture::MimeType::Png) => "image/png".to_string(),
        Some(lofty::picture::MimeType::Bmp) => "image/bmp".to_string(),
        Some(lofty::picture::MimeType::Gif) => "image/gif".to_string(),
        Some(lofty::picture::MimeType::Tiff) => "image/tiff".to_string(),
        _ => "image/jpeg".to_string(),
    };

    Some((mime, picture.data().to_vec()))
}

/// Writes the cover to `{covers_dir}/{content_md5}.{ext}` (idempotent by
/// content hash, so equal covers dedupe) and returns its absolute path.
pub fn write_cover_file(
    covers_dir: &Path,
    mime: &str,
    bytes: &[u8],
) -> MetadataResult<Option<String>> {
    let ext = match mime {
        "image/png" => "png",
        "image/bmp" => "bmp",
        "image/gif" => "gif",
        "image/tiff" => "tiff",
        _ => "jpg",
    };

    fs::create_dir_all(covers_dir)?;

    let hash = format!("{:x}", Md5::digest(bytes));
    let path = covers_dir.join(format!("{}.{}", hash, ext));

    if !path.exists() {
        fs::write(&path, bytes)?;
    }

    // Best-effort thumbnail; a missing thumb (unsupported format) falls back
    // to the full image in the UI.
    write_thumbnail(&path, bytes)?;

    Ok(Some(path.to_string_lossy().to_string()))
}

/// Returns the expected thumbnail path for a full cover file, derived by
/// naming convention: `covers/{hash}.{ext}` → `covers/thumb_{hash}.jpg`.
pub fn thumb_path_for(full_path: &Path) -> PathBuf {
    let dir = full_path.parent().unwrap_or(Path::new(""));
    let stem = full_path.file_stem().unwrap_or_default().to_string_lossy();
    dir.join(format!("thumb_{}.jpg", stem))
}

/// Downsizes an embedded cover to a ~256px JPEG thumbnail next to the full
/// file. Best-effort: any failure (e.g. a format we didn't compile in) is
/// silently ignored so the UI falls back to the full image.
pub fn write_thumbnail(full_path: &Path, bytes: &[u8]) -> MetadataResult<()> {
    let Ok(img) = image::load_from_memory(bytes) else {
        return Ok(());
    };
    let thumb = img.thumbnail(256, 256);
    let mut out = Vec::new();
    if thumb
        .write_to(&mut Cursor::new(&mut out), image::ImageFormat::Jpeg)
        .is_err()
    {
        return Ok(());
    }

    let thumb_path = thumb_path_for(full_path);
    if !thumb_path.exists() {
        fs::write(&thumb_path, &out)?;
    }

    Ok(())
}

/// Parses a legacy `data:<mime>;base64,<payload>` artwork value, writes the
/// decoded bytes to the covers dir and returns the absolute file path.
///
/// Returns `Ok(None)` when the value is not a base64 data URL, so the caller
/// can leave the row untouched (idempotent migration).
pub fn cover_path_from_data_url(
    covers_dir: &Path,
    data_url: &str,
) -> MetadataResult<Option<String>> {
    let rest = data_url.strip_prefix("data:").unwrap_or(data_url);
    let (mime, payload) = match rest.split_once(";base64,") {
        Some((m, p)) => (m, p.trim()),
        None => return Ok(None),
    };

    let bytes = STANDARD.decode(payload)?;
    write_cover_file(covers_dir, mime, &bytes)
}

/// Synchronous core of metadata extraction (lofty read + cover file write).
/// Runs on a blocking thread (`spawn_blocking`) so the async runtime isn't
/// blocked. This is the unit the incremental scan parallelizes.
pub fn extract_metadata_blocking(
    path: &str,
    covers_dir: &Path,
) -> MetadataResult<AudioMetadata> {
    let tagged_file = read_from_path(path)?;

    let properties = tagged_file.properties();
    let mut metadata = AudioMetadata {
        title: None,
        artist: None,
        release: None,
        genre: None,
        year: None,
        track: None,
        disc: None,
        duration: properties.duration().as_secs_f64(),
        bitrate: properties.audio_bitrate(),
        sample_rate: properties.sample_rate(),
        channels: properties.channels(),
        cover_image_base64: None,
        cover_path: None,
        all_fields: HashMap::new(),
        file_path: path.to_string(),
    };

    if let Some(tag) = tagged_file.primary_tag() {
        // Standard fields
        metadata.title = tag.title().map(|s| s.to_string());
        metadata.artist = tag.artist().map(|s| s.to_string());
        metadata.release = tag.album().map(|s| s.to_string());
        metadata.genre = tag.genre().map(|s| s.to_string());
        metadata.year = tag.year();
        metadata.track = tag.track();
        metadata.disc = tag.disk();

        // Extract cover: persist as file (new) AND keep base64 (legacy/compat).
        if let Some((mime, bytes)) = extract_cover_bytes(tag) {
            let base64 = STANDARD.encode(&bytes);
            metadata.cover_image_base64 = Some(format!("data:{};base64,{}", mime, base64));
            metadata.cover_path = write_cover_file(covers_dir, &mime, &bytes)?;
        }

        // All fields as key-value pairs
        for item in tag.items() {
            metadata
                .all_fields
                .insert(format!("{:?}", item.key()), format!("{:?}", item.value()));
        }
    }

    Ok(metadata)
}