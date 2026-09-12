//! Persistence for downloaded artwork. Network bytes are validated before an
//! atomic move into the same content-addressed directory used by local covers.

use crate::api::{CoreError, CoreResult};
use image::{ImageFormat, ImageReader};
use md5::{Digest, Md5};
use std::fs::{self, OpenOptions};
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};

fn storage(error: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: format!("Managed artwork: {error}"),
    }
}

pub fn write_managed(covers_dir: &Path, bytes: &[u8]) -> CoreResult<PathBuf> {
    crate::metadata::validate_artwork_bytes(bytes).map_err(storage)?;
    let format = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(storage)?
        .format()
        .ok_or_else(|| storage("Unknown image format"))?;
    let extension = match format {
        ImageFormat::Jpeg => "jpg",
        ImageFormat::Png => "png",
        _ => return Err(storage("Artwork must be JPEG or PNG")),
    };
    fs::create_dir_all(covers_dir).map_err(storage)?;
    let canonical_dir = fs::canonicalize(covers_dir).map_err(storage)?;
    let hash = format!("{:x}", Md5::digest(bytes));
    let destination = canonical_dir.join(format!("{hash}.{extension}"));
    if destination.exists() {
        let existing = fs::canonicalize(&destination).map_err(storage)?;
        if !existing.starts_with(&canonical_dir) || !existing.is_file() {
            return Err(storage("Existing artwork path is unsafe"));
        }
        return Ok(existing);
    }

    let mut temporary = None;
    for attempt in 0..32u32 {
        let candidate = canonical_dir.join(format!(
            ".remote-{hash}-{}-{attempt}.tmp",
            std::process::id()
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => {
                temporary = Some((candidate, file));
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(storage(error)),
        }
    }
    let (temporary_path, mut file) =
        temporary.ok_or_else(|| storage("Unable to create temporary artwork file"))?;
    let result = (|| -> CoreResult<()> {
        file.write_all(bytes).map_err(storage)?;
        file.sync_all().map_err(storage)?;
        drop(file);
        fs::rename(&temporary_path, &destination).map_err(storage)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary_path);
    }
    result?;
    crate::metadata::write_thumbnail(&destination, bytes).map_err(storage)?;
    Ok(destination)
}

/// Removes only a content-addressed file created by this module and its
/// derived thumbnail. Missing or external paths are deliberately ignored.
pub fn remove_managed_if_safe(covers_dir: &Path, path: &Path) -> CoreResult<bool> {
    let canonical_dir = match fs::canonicalize(covers_dir) {
        Ok(path) => path,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(storage(error)),
    };
    let canonical_path = match fs::canonicalize(path) {
        Ok(path) => path,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(storage(error)),
    };
    let stem = canonical_path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    let extension = canonical_path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    if !canonical_path.starts_with(&canonical_dir)
        || !canonical_path.is_file()
        || stem.len() != 32
        || !stem.bytes().all(|value| value.is_ascii_hexdigit())
        || !matches!(extension, "jpg" | "png")
    {
        return Ok(false);
    }
    fs::remove_file(&canonical_path).map_err(storage)?;
    let thumbnail = crate::metadata::thumb_path_for(&canonical_path);
    match fs::remove_file(thumbnail) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(storage(error)),
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn png() -> Vec<u8> {
        let image = image::DynamicImage::new_rgb8(2, 2);
        let mut bytes = Vec::new();
        image
            .write_to(&mut Cursor::new(&mut bytes), ImageFormat::Png)
            .unwrap();
        bytes
    }

    #[test]
    fn validates_deduplicates_and_leaves_no_temporary_file() {
        let directory =
            std::env::temp_dir().join(format!("durvald-remote-artwork-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        let first = write_managed(&directory, &png()).unwrap();
        let second = write_managed(&directory, &png()).unwrap();
        assert_eq!(first, second);
        assert!(first.starts_with(fs::canonicalize(&directory).unwrap()));
        assert!(fs::read_dir(&directory).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".tmp")
        }));
        assert!(write_managed(&directory, b"not an image").is_err());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn cleanup_removes_only_managed_content_addressed_files() {
        let directory =
            std::env::temp_dir().join(format!("durvald-remote-cleanup-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        let managed = write_managed(&directory, &png()).unwrap();
        let unrelated = directory.join("keep.jpg");
        fs::write(&unrelated, &png()).unwrap();
        assert!(!remove_managed_if_safe(&directory, &unrelated).unwrap());
        assert!(unrelated.exists());
        assert!(remove_managed_if_safe(&directory, &managed).unwrap());
        assert!(!managed.exists());
        assert!(!crate::metadata::thumb_path_for(&managed).exists());
        fs::remove_dir_all(directory).unwrap();
    }
}
