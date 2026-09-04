//! Metadata extraction module using lofty

use image;
use lofty::file::AudioFile;
use lofty::file::TaggedFileExt;
use lofty::read_from_path;
use lofty::tag::Accessor;
use lofty::tag::ItemKey;
use md5::{Digest, Md5};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum MetadataError {
    #[error("Lofty error: {0}")]
    Lofty(#[from] lofty::error::LoftyError),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Image error: {0}")]
    Image(#[from] image::ImageError),
    #[error("{0}")]
    Custom(String),
}

pub type MetadataResult<T> = Result<T, MetadataError>;

fn cancellation_requested(cancel_requested: Option<&AtomicBool>) -> bool {
    cancel_requested.is_some_and(|cancel| cancel.load(Ordering::Acquire))
}

/// Returns a bounded ReplayGain track adjustment in dB when the file carries
/// a valid `REPLAYGAIN_TRACK_GAIN` tag. Missing or invalid tags leave audio
/// playback unchanged.
pub fn replay_gain_db(path: &str) -> Option<f64> {
    let tagged_file = read_from_path(path).ok()?;
    let value = tagged_file
        .primary_tag()?
        .get_string(&ItemKey::ReplayGainTrackGain)?;
    parse_replay_gain_db(value)
}

fn parse_replay_gain_db(value: &str) -> Option<f64> {
    let value = value.trim().strip_suffix("dB").unwrap_or(value).trim();
    let gain = value.parse::<f64>().ok()?;
    gain.is_finite()
        .then_some(gain)
        .filter(|gain| (-24.0..=24.0).contains(gain))
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct AudioMetadata {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub track_artists: Vec<String>,
    pub album_artist: Option<String>,
    pub release: Option<String>,
    pub genre: Option<String>,
    pub year: Option<u32>,
    pub track: Option<u32>,
    pub disc: Option<u32>,
    pub duration: f64,
    pub bitrate: Option<u32>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u8>,
    /// Absolute path of the cover file. Empty only when the track has no
    /// embedded artwork.
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

/// Synchronous core of metadata extraction (lofty read + cover file write).
/// Runs on a blocking thread (`spawn_blocking`) so the async runtime isn't
/// blocked. This is the unit the incremental scan parallelizes.
pub fn extract_metadata_blocking(path: &str, covers_dir: &Path) -> MetadataResult<AudioMetadata> {
    extract_metadata_blocking_with_cancel(path, covers_dir, None)
}

/// Cancellation-aware variant of [`extract_metadata_blocking`].
///
/// `lofty` performs a synchronous decode, so a cancellation request cannot
/// safely interrupt that individual decoder call. We do, however, check at
/// every boundary around it and avoid cover writes or accepting its result
/// after cancellation.
pub fn extract_metadata_blocking_with_cancel(
    path: &str,
    covers_dir: &Path,
    cancel_requested: Option<&AtomicBool>,
) -> MetadataResult<AudioMetadata> {
    if cancellation_requested(cancel_requested) {
        return Err(MetadataError::Custom(
            "Metadata extraction cancelled".to_string(),
        ));
    }
    let tagged_file = read_from_path(path)?;

    if cancellation_requested(cancel_requested) {
        return Err(MetadataError::Custom(
            "Metadata extraction cancelled".to_string(),
        ));
    }

    let properties = tagged_file.properties();
    let mut metadata = AudioMetadata {
        title: None,
        artist: None,
        track_artists: Vec::new(),
        album_artist: None,
        release: None,
        genre: None,
        year: None,
        track: None,
        disc: None,
        duration: properties.duration().as_secs_f64(),
        bitrate: properties.audio_bitrate(),
        sample_rate: properties.sample_rate(),
        channels: properties.channels(),
        cover_path: None,
        all_fields: HashMap::new(),
        file_path: path.to_string(),
    };

    if let Some(tag) = tagged_file.primary_tag() {
        // Standard fields
        metadata.title = tag.title().map(|s| s.to_string());
        metadata.artist = tag.artist().map(|s| s.to_string());
        metadata.track_artists = tag
            .get_strings(&ItemKey::TrackArtists)
            .flat_map(split_artist_credit)
            .collect();
        if metadata.track_artists.is_empty() {
            metadata.track_artists = metadata
                .artist
                .as_deref()
                .map(split_artist_credit)
                .unwrap_or_default();
        }
        metadata.album_artist = tag
            .get_string(&ItemKey::AlbumArtist)
            .map(|artist| artist.to_string());
        metadata.release = tag.album().map(|s| s.to_string());
        metadata.genre = tag.genre().map(|s| s.to_string());
        metadata.year = tag.year();
        metadata.track = tag.track();
        metadata.disc = tag.disk();

        // Extract cover directly to the managed covers directory.
        if let Some((mime, bytes)) = extract_cover_bytes(tag) {
            if cancellation_requested(cancel_requested) {
                return Err(MetadataError::Custom(
                    "Metadata extraction cancelled".to_string(),
                ));
            }
            metadata.cover_path = write_cover_file(covers_dir, &mime, &bytes)?;
        }

        // All fields as key-value pairs
        for item in tag.items() {
            if cancellation_requested(cancel_requested) {
                return Err(MetadataError::Custom(
                    "Metadata extraction cancelled".to_string(),
                ));
            }
            metadata
                .all_fields
                .insert(format!("{:?}", item.key()), format!("{:?}", item.value()));
        }
    }

    Ok(metadata)
}

pub(crate) fn split_artist_credit(credit: &str) -> Vec<String> {
    if credit.contains(" / ") {
        let mut artists = Vec::new();
        for artist in credit.split(" / ").flat_map(split_artist_credit) {
            if !artists
                .iter()
                .any(|existing: &String| existing.eq_ignore_ascii_case(&artist))
            {
                artists.push(artist);
            }
        }
        return artists;
    }

    let lower = credit.to_ascii_lowercase();
    let feature = [" feat. ", " feat ", " featuring ", " ft. ", " ft "]
        .into_iter()
        .find_map(|marker| lower.find(marker).map(|index| (index, marker.len())));

    let Some((index, marker_length)) = feature else {
        let artist = credit.trim();
        return (!artist.is_empty()).then(|| artist.to_string()).into_iter().collect();
    };

    let mut artists = Vec::new();
    let primary = credit[..index].trim();
    if !primary.is_empty() {
        artists.push(primary.to_string());
    }

    let guests = credit[index + marker_length..]
        .replace(" & ", "\n")
        .replace(", ", "\n")
        .replace("; ", "\n");
    for guest in guests.lines().map(str::trim).filter(|artist| !artist.is_empty()) {
        if !artists.iter().any(|artist| artist.eq_ignore_ascii_case(guest)) {
            artists.push(guest.to_string());
        }
    }
    artists
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancelled_extraction_stops_before_reading_the_file() {
        let cancelled = AtomicBool::new(true);
        let error = extract_metadata_blocking_with_cancel(
            "/path/that-must-not-be-read.mp3",
            Path::new("/tmp"),
            Some(&cancelled),
        )
        .expect_err("a cancelled extraction must not read the path");

        assert!(error.to_string().contains("cancelled"));
    }

    #[test]
    fn replay_gain_parser_accepts_valid_bounded_db_values() {
        assert_eq!(parse_replay_gain_db("-7.25 dB"), Some(-7.25));
        assert_eq!(parse_replay_gain_db("+3.0"), Some(3.0));
        assert_eq!(parse_replay_gain_db("not a number"), None);
        assert_eq!(parse_replay_gain_db("25 dB"), None);
    }
}
