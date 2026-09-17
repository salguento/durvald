//! Serialized metadata edits with a durable journal and atomic file replacement.
use crate::api::{CoreError, CoreResult, TrackInfo, TrackMetadataEdit};
use crate::database::operations::{self, DatabaseResult};
use lofty::config::WriteOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::tag::{Accessor, ItemKey, Tag};
use rusqlite::{Connection, OptionalExtension, params};
use std::fs::{self, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FILE: AtomicU64 = AtomicU64::new(0);

pub(crate) fn create_tables(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS track_metadata_cache (
        song_id INTEGER PRIMARY KEY REFERENCES songs(song_id) ON DELETE CASCADE,
        payload TEXT NOT NULL, is_override INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS track_metadata_changes (
        change_id INTEGER PRIMARY KEY, song_id INTEGER NOT NULL,
        before_payload TEXT NOT NULL, after_payload TEXT NOT NULL,
        before_override INTEGER NOT NULL, write_to_file INTEGER NOT NULL,
        file_path TEXT NOT NULL, backup_path TEXT, file_hash_after TEXT,
        status TEXT NOT NULL, error TEXT,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
        CREATE INDEX IF NOT EXISTS idx_track_metadata_changes
        ON track_metadata_changes(song_id, change_id);",
    )?;
    let has_file_hash = conn
        .prepare("PRAGMA table_info(track_metadata_changes)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "file_hash_after");
    if !has_file_hash {
        conn.execute(
            "ALTER TABLE track_metadata_changes ADD COLUMN file_hash_after TEXT",
            [],
        )?;
    }
    Ok(())
}

fn storage(error: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        message: error.to_string(),
    }
}

fn field(md: &crate::metadata::AudioMetadata, key: &str) -> String {
    let value = md.all_fields.get(key).cloned().unwrap_or_default();
    value
        .strip_prefix("Text(")
        .and_then(|v| v.strip_suffix(')'))
        .and_then(|v| serde_json::from_str::<String>(v).ok())
        .unwrap_or(value)
}

pub(crate) fn from_extracted(md: &crate::metadata::AudioMetadata) -> TrackMetadataEdit {
    TrackMetadataEdit {
        title: md.title.clone().unwrap_or_default(),
        artist: md.artist.clone().unwrap_or_default(),
        album_artist: md.album_artist.clone().unwrap_or_default(),
        album: md.release.clone().unwrap_or_default(),
        genre: md.genre.clone().unwrap_or_default(),
        year: md.year,
        track_number: md.track,
        disc_number: md.disc,
        composer: field(md, "Composer"),
        comment: field(md, "Comment"),
    }
}

fn apply(md: &mut crate::metadata::AudioMetadata, edit: &TrackMetadataEdit) {
    md.title = Some(edit.title.clone());
    md.artist = Some(edit.artist.clone());
    md.track_artists = vec![edit.artist.clone()];
    md.album_artist = (!edit.album_artist.is_empty()).then(|| edit.album_artist.clone());
    md.release = Some(edit.album.clone());
    md.genre = (!edit.genre.is_empty()).then(|| edit.genre.clone());
    md.year = edit.year;
    md.track = edit.track_number;
    md.disc = edit.disc_number;
    md.all_fields
        .insert("Composer".into(), edit.composer.clone());
    md.all_fields.insert("Comment".into(), edit.comment.clone());
}

pub(crate) fn apply_override(
    conn: &Connection,
    md: &mut crate::metadata::AudioMetadata,
) -> DatabaseResult<()> {
    let payload: Option<String> = conn
        .query_row(
            "SELECT c.payload FROM track_metadata_cache c JOIN songs s USING(song_id)
         WHERE s.file_path=?1 AND c.is_override=1",
            [&md.file_path],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(payload) = payload {
        let edit = serde_json::from_str(&payload).map_err(|e| {
            operations::DatabaseError::Custom(format!("Invalid metadata override: {e}"))
        })?;
        apply(md, &edit);
    }
    Ok(())
}

pub(crate) fn cache_scanned(
    conn: &Connection,
    path: &str,
    edit: &TrackMetadataEdit,
) -> DatabaseResult<()> {
    let payload = serde_json::to_string(edit)
        .map_err(|e| operations::DatabaseError::Custom(e.to_string()))?;
    conn.execute(
        "INSERT INTO track_metadata_cache(song_id,payload)
        SELECT song_id,?2 FROM songs WHERE file_path=?1
        ON CONFLICT(song_id) DO UPDATE SET payload=excluded.payload
        WHERE track_metadata_cache.is_override=0",
        params![path, payload],
    )?;
    Ok(())
}

fn read_editable_tags(path: &str) -> CoreResult<TrackMetadataEdit> {
    let file = lofty::probe::Probe::open(path)
        .map_err(storage)?
        .guess_file_type()
        .map_err(storage)?
        .read()
        .map_err(storage)?;
    let tag = file
        .primary_tag()
        .or_else(|| file.first_tag())
        .ok_or_else(|| storage("O arquivo não possui tags editáveis"))?;
    Ok(TrackMetadataEdit {
        title: tag
            .title()
            .map(|value| value.into_owned())
            .unwrap_or_default(),
        artist: tag
            .artist()
            .map(|value| value.into_owned())
            .unwrap_or_default(),
        album_artist: tag
            .get_string(&ItemKey::AlbumArtist)
            .unwrap_or_default()
            .to_string(),
        album: tag
            .album()
            .map(|value| value.into_owned())
            .unwrap_or_default(),
        genre: tag
            .genre()
            .map(|value| value.into_owned())
            .unwrap_or_default(),
        year: tag.year(),
        track_number: tag.track(),
        disc_number: tag.disk(),
        composer: tag
            .get_string(&ItemKey::Composer)
            .unwrap_or_default()
            .to_string(),
        comment: tag
            .get_string(&ItemKey::Comment)
            .unwrap_or_default()
            .to_string(),
    })
}

/// Backfill pre-editor libraries once. Never present missing cached fields as
/// empty values, which could erase existing tags on the user's first edit.
pub(crate) fn ensure_cached(conn: &Connection, id: i64) -> CoreResult<()> {
    let exists: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM track_metadata_cache WHERE song_id=?1)",
            [id],
            |r| r.get(0),
        )
        .map_err(storage)?;
    if !exists {
        let current = info(conn, id)?;
        // A disconnected/read-only library can still use database-only edits.
        // File-backed saves will report the actual I/O error later.
        let metadata = read_editable_tags(&current.track.file_path).unwrap_or(current.metadata);
        cache_scanned(conn, &current.track.file_path, &metadata).map_err(storage)?;
    }
    Ok(())
}

pub(crate) fn info(conn: &Connection, id: i64) -> CoreResult<TrackInfo> {
    let song = operations::get_song_by_id(conn, &id.to_string())
        .map_err(storage)?
        .into_iter()
        .next()
        .ok_or_else(|| CoreError::NotFound {
            message: "Faixa não encontrada".into(),
        })?;
    let cached: Option<String> = conn
        .query_row(
            "SELECT payload FROM track_metadata_cache WHERE song_id=?1",
            [id],
            |r| r.get(0),
        )
        .optional()
        .map_err(storage)?;
    let metadata = if let Some(payload) = cached {
        serde_json::from_str(&payload).map_err(storage)?
    } else {
        TrackMetadataEdit {
            title: song.title.clone(),
            artist: song.artist_name.clone(),
            album: song.release_title.clone(),
            album_artist: String::new(),
            genre: String::new(),
            year: None,
            track_number: Some(song.track_number.into()),
            disc_number: Some(song.disc_number.into()),
            composer: String::new(),
            comment: String::new(),
        }
    };
    let can_undo = conn.query_row("SELECT EXISTS(SELECT 1 FROM track_metadata_changes WHERE song_id=?1 AND status='applied')",
        [id], |r| r.get(0)).map_err(storage)?;
    Ok(TrackInfo {
        track: crate::core::track_from_song(song),
        metadata,
        can_undo,
    })
}

fn validate(edit: &TrackMetadataEdit) -> CoreResult<()> {
    if edit.title.trim().is_empty() || edit.artist.trim().is_empty() || edit.album.trim().is_empty()
    {
        return Err(CoreError::InvalidInput {
            message: "Título, artista e álbum são obrigatórios".into(),
        });
    }
    if edit.track_number.is_some_and(|n| n > 255)
        || edit.disc_number.is_some_and(|n| n > 255)
        || edit.year.is_some_and(|n| n > 9999 || n == 0)
    {
        return Err(CoreError::InvalidInput {
            message: "Ano inválido ou número de faixa/disco fora de 0–255".into(),
        });
    }
    Ok(())
}

/// Update only edited keys on every existing tag, retaining pictures and other fields.
fn write_tags(path: &Path, edit: &TrackMetadataEdit) -> CoreResult<()> {
    let mut file = lofty::probe::Probe::open(path)
        .map_err(storage)?
        .guess_file_type()
        .map_err(storage)?
        .read()
        .map_err(storage)?;
    if file.tags().is_empty() {
        file.insert_tag(Tag::new(file.primary_tag_type()));
    }
    let tag_types: Vec<_> = file.tags().iter().map(|tag| tag.tag_type()).collect();
    for tag_type in tag_types {
        let tag = file.tag_mut(tag_type).expect("existing tag");
        tag.set_title(edit.title.clone());
        tag.set_artist(edit.artist.clone());
        tag.set_album(edit.album.clone());
        for (key, value) in [
            (ItemKey::AlbumArtist, &edit.album_artist),
            (ItemKey::Genre, &edit.genre),
            (ItemKey::Composer, &edit.composer),
            (ItemKey::Comment, &edit.comment),
        ] {
            tag.remove_key(&key);
            if !value.is_empty() {
                tag.insert_text(key, value.clone());
            }
        }
        tag.remove_key(&ItemKey::Year);
        tag.remove_key(&ItemKey::RecordingDate);
        if let Some(n) = edit.year {
            tag.set_year(n);
        }
        tag.remove_key(&ItemKey::TrackNumber);
        if let Some(n) = edit.track_number {
            tag.set_track(n);
        }
        tag.remove_key(&ItemKey::DiscNumber);
        if let Some(n) = edit.disc_number {
            tag.set_disk(n);
        }
    }
    let mut destination = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(storage)?;
    file.save_to(&mut destination, WriteOptions::default())
        .map_err(storage)?;
    destination.sync_all().map_err(storage)?;
    // Reject silent failures/unsupported tag mappings before replacing the original.
    let checked = lofty::probe::Probe::open(path)
        .map_err(storage)?
        .guess_file_type()
        .map_err(storage)?
        .read()
        .map_err(storage)?;
    let tag = checked
        .primary_tag()
        .or_else(|| checked.first_tag())
        .ok_or_else(|| storage("O formato não suporta tags editáveis"))?;
    if tag.title().as_deref() != Some(&edit.title)
        || tag.artist().as_deref() != Some(&edit.artist)
        || tag.album().as_deref() != Some(&edit.album)
        || tag.get_string(&ItemKey::AlbumArtist).unwrap_or_default() != edit.album_artist
        || tag.genre().as_deref().unwrap_or_default() != edit.genre
        || tag.get_string(&ItemKey::Composer).unwrap_or_default() != edit.composer
        || tag.get_string(&ItemKey::Comment).unwrap_or_default() != edit.comment
        || tag.year() != edit.year
        || tag.track() != edit.track_number
        || tag.disk() != edit.disc_number
    {
        return Err(storage("O formato não preservou as tags editadas"));
    }
    Ok(())
}

fn unique_path(parent: &Path, suffix: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    parent.join(format!(
        ".durvald-metadata-{}-{nanos}-{}-{suffix}",
        std::process::id(),
        NEXT_FILE.fetch_add(1, Ordering::Relaxed)
    ))
}

fn copy_exclusive(source: &Path, target: &Path) -> CoreResult<()> {
    let mut input = fs::File::open(source).map_err(storage)?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(target)
        .map_err(storage)?;
    std::io::copy(&mut input, &mut output).map_err(storage)?;
    fs::set_permissions(target, input.metadata().map_err(storage)?.permissions())
        .map_err(storage)?;
    output.sync_all().map_err(storage)
}

fn file_hash(path: &Path) -> CoreResult<String> {
    use md5::{Digest, Md5};
    use std::io::Read;
    let mut file = fs::File::open(path).map_err(storage)?;
    let mut hash = Md5::new();
    let mut buffer = [0_u8; 65536];
    loop {
        let count = file.read(&mut buffer).map_err(storage)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hash.finalize()))
}

fn replace_from(source: &Path, target: &Path, edit: Option<&TrackMetadataEdit>) -> CoreResult<()> {
    let staged = unique_path(
        target
            .parent()
            .ok_or_else(|| storage("Arquivo sem diretório"))?,
        "stage",
    );
    let result = (|| {
        copy_exclusive(source, &staged)?;
        if let Some(edit) = edit {
            write_tags(&staged, edit)?;
        }
        fs::rename(&staged, target).map_err(storage)?;
        Ok(())
    })();
    if staged.exists() {
        let _ = fs::remove_file(&staged);
    }
    result
}

/// Index the edited identity through the existing import machinery, retaining IDs,
/// playlists, playback counts, ratings, cover and MusicBrainz evidence.
fn update_index(
    conn: &Connection,
    id: i64,
    edit: &TrackMetadataEdit,
    is_override: bool,
    change: (i64, &str),
) -> CoreResult<()> {
    let old = info(conn, id)?.track;
    let payload = serde_json::to_string(edit).map_err(storage)?;
    let tx = conn.unchecked_transaction().map_err(storage)?;
    let artist = edit.artist.clone();
    operations::add_artist(&tx, artist.clone()).map_err(storage)?;
    let album_artist = if edit.album_artist.is_empty() {
        artist.clone()
    } else {
        edit.album_artist.clone()
    };
    operations::add_artist(&tx, album_artist.clone()).map_err(storage)?;
    let group = crate::database::models::ReleaseGroup {
        title: edit.album.clone(),
        artist: album_artist.clone(),
        artwork: old.artwork_id.clone().unwrap_or_default(),
        tracks: 0,
        disc: edit.disc_number.unwrap_or(1),
        date: edit.year.unwrap_or(0),
        duration: 0,
    };
    operations::add_release(&tx, &group).map_err(storage)?;
    let artist_id: i64 = tx
        .query_row(
            "SELECT artist_id FROM artists WHERE name=?1",
            [&artist],
            |r| r.get(0),
        )
        .map_err(storage)?;
    let album_artist_id: i64 = tx
        .query_row(
            "SELECT artist_id FROM artists WHERE name=?1",
            [&album_artist],
            |r| r.get(0),
        )
        .map_err(storage)?;
    let release_id: i64 = tx
        .query_row(
            "SELECT release_id FROM releases WHERE title=?1 AND artist_id=?2",
            params![edit.album, album_artist_id],
            |r| r.get(0),
        )
        .map_err(storage)?;
    tx.execute(
        "UPDATE songs SET title=?2,artist_name=?3,artist_id=?4,release_title=?5,release_id=?6,
        track_number=?7,disc_number=?8,updated_at=CURRENT_TIMESTAMP WHERE song_id=?1",
        params![
            id,
            edit.title,
            edit.artist,
            artist_id,
            edit.album,
            release_id,
            edit.track_number.unwrap_or(0),
            edit.disc_number.unwrap_or(1)
        ],
    )
    .map_err(storage)?;
    if old.artist != edit.artist {
        tx.execute("DELETE FROM song_artists WHERE song_id=?1", [id])
            .map_err(storage)?;
        tx.execute(
            "INSERT OR IGNORE INTO song_artists(song_id,artist_id,position) VALUES (?1,?2,0)",
            params![id, artist_id],
        )
        .map_err(storage)?;
    }
    tx.execute("INSERT INTO track_metadata_cache(song_id,payload,is_override) VALUES (?1,?2,?3)
        ON CONFLICT(song_id) DO UPDATE SET payload=excluded.payload,is_override=excluded.is_override",
        params![id,payload,is_override]).map_err(storage)?;
    for release in [old.release_id, release_id] {
        tx.execute(
            "UPDATE releases SET
            total_tracks=(SELECT COUNT(*) FROM songs WHERE release_id=?1),
            total_discs=COALESCE((SELECT MAX(disc_number) FROM songs WHERE release_id=?1),1),
            duration=COALESCE((SELECT SUM(duration) FROM songs WHERE release_id=?1),0)
            WHERE release_id=?1",
            [release],
        )
        .map_err(storage)?;
    }
    tx.execute(
        "DELETE FROM releases
         WHERE release_id=?1
           AND NOT EXISTS (SELECT 1 FROM songs WHERE songs.release_id=releases.release_id)",
        [old.release_id],
    )
    .map_err(storage)?;
    tx.execute(
        "DELETE FROM artists
         WHERE NOT EXISTS (SELECT 1 FROM releases WHERE releases.artist_id=artists.artist_id)
           AND NOT EXISTS (SELECT 1 FROM songs WHERE songs.artist_id=artists.artist_id)
           AND NOT EXISTS (SELECT 1 FROM song_artists WHERE song_artists.artist_id=artists.artist_id)",
        [],
    ).map_err(storage)?;
    tx.execute(
        "UPDATE track_metadata_changes SET status=?2 WHERE change_id=?1",
        params![change.0, change.1],
    )
    .map_err(storage)?;
    tx.commit().map_err(storage)
}

pub(crate) fn save(
    conn: &Connection,
    id: i64,
    edit: TrackMetadataEdit,
    write_file: bool,
    backup_dir: &Path,
) -> CoreResult<TrackInfo> {
    validate(&edit)?;
    let before = info(conn, id)?;
    let override_before: bool = conn
        .query_row(
            "SELECT COALESCE((SELECT is_override FROM track_metadata_cache WHERE song_id=?1),0)",
            [id],
            |r| r.get(0),
        )
        .map_err(storage)?;
    let before_payload = serde_json::to_string(&before.metadata).map_err(storage)?;
    let after_payload = serde_json::to_string(&edit).map_err(storage)?;
    conn.execute("INSERT INTO track_metadata_changes(song_id,before_payload,after_payload,before_override,write_to_file,file_path,status)
        VALUES (?1,?2,?3,?4,?5,?6,'pending')", params![id,before_payload,after_payload,override_before,write_file,before.track.file_path]).map_err(storage)?;
    let change_id = conn.last_insert_rowid();
    let mut backup = None;
    let mut target = None;
    let result = (|| {
        if write_file {
            let path = fs::canonicalize(&before.track.file_path).map_err(storage)?;
            if fs::metadata(&path)
                .map_err(storage)?
                .permissions()
                .readonly()
            {
                return Err(storage("Arquivo somente leitura"));
            }
            fs::create_dir_all(backup_dir).map_err(storage)?;
            let backup_path = unique_path(backup_dir, "backup");
            copy_exclusive(&path, &backup_path)?;
            conn.execute(
                "UPDATE track_metadata_changes SET backup_path=?2 WHERE change_id=?1",
                params![change_id, backup_path.to_string_lossy()],
            )
            .map_err(storage)?;
            replace_from(&backup_path, &path, Some(&edit))?;
            backup = Some(backup_path);
            target = Some(path);
            let hash = file_hash(target.as_ref().expect("file target"))?;
            conn.execute("UPDATE track_metadata_changes SET status='file_saved',file_hash_after=?2 WHERE change_id=?1", params![change_id,hash]).map_err(storage)?;
        }
        update_index(conn, id, &edit, !write_file, (change_id, "applied"))
    })();
    if let Err(ref error) = result {
        if let (Some(backup), Some(target)) = (&backup, &target) {
            // If DB persistence failed, restore the original bytes; the backup
            // and journal remain available even if restoration also fails.
            if replace_from(backup, target, None).is_err() {
                let _ = conn.execute(
                    "UPDATE track_metadata_changes SET error=?2 WHERE change_id=?1",
                    params![change_id, error.to_string()],
                );
                return Err(storage(
                    "Falha ao atualizar o índice e restaurar o arquivo. Backup preservado no histórico.",
                ));
            }
        }
        let _ = conn.execute(
            "UPDATE track_metadata_changes SET status='failed',error=?2 WHERE change_id=?1",
            params![change_id, error.to_string()],
        );
    }
    result?;
    info(conn, id)
}

pub(crate) fn undo(conn: &Connection, id: i64) -> CoreResult<TrackInfo> {
    let (change_id, payload, is_override, write_file, path, backup, expected_hash): (i64,String,bool,bool,String,Option<String>,Option<String>) = conn.query_row(
        "SELECT change_id,before_payload,before_override,write_to_file,file_path,backup_path,file_hash_after
         FROM track_metadata_changes WHERE song_id=?1 AND status='applied' ORDER BY change_id DESC LIMIT 1",
        [id], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?))).map_err(storage)?;
    let edit = serde_json::from_str(&payload).map_err(storage)?;
    let mut rollback = None;
    if write_file {
        let backup = backup.ok_or_else(|| storage("Backup de metadados ausente"))?;
        let target = fs::canonicalize(path).map_err(storage)?;
        if expected_hash.as_deref() != Some(file_hash(&target)?.as_str()) {
            return Err(storage(
                "O arquivo foi alterado fora do Durvald. Desfazer foi bloqueado para preservar essas alterações.",
            ));
        }
        let previous = unique_path(
            Path::new(&backup)
                .parent()
                .ok_or_else(|| storage("Backup inválido"))?,
            "undo-backup",
        );
        copy_exclusive(&target, &previous)?;
        replace_from(Path::new(&backup), &target, None)?;
        rollback = Some((previous, target));
    }
    if let Err(error) = update_index(conn, id, &edit, is_override, (change_id, "undone")) {
        if let Some((previous, target)) = &rollback {
            replace_from(previous, target, None)?;
            let _ = fs::remove_file(previous);
        }
        return Err(error);
    }
    if let Some((previous, _)) = &rollback {
        let _ = fs::remove_file(previous);
    }
    info(conn, id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn draft() -> TrackMetadataEdit {
        TrackMetadataEdit {
            title: "Original".into(),
            artist: "Artist".into(),
            album_artist: "".into(),
            album: "Album".into(),
            genre: "Rock".into(),
            year: Some(2024),
            track_number: Some(1),
            disc_number: Some(1),
            composer: "Composer".into(),
            comment: "Comment".into(),
        }
    }

    fn fixture() -> (Connection, PathBuf, PathBuf) {
        let dir = unique_path(&std::env::temp_dir(), "test");
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join("track.wav");
        let samples = vec![0_u8; 8820];
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36_u32 + samples.len() as u32).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16_u32.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&1_u16.to_le_bytes());
        bytes.extend_from_slice(&44100_u32.to_le_bytes());
        bytes.extend_from_slice(&88200_u32.to_le_bytes());
        bytes.extend_from_slice(&2_u16.to_le_bytes());
        bytes.extend_from_slice(&16_u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&(samples.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&samples);
        fs::write(&file, bytes).unwrap();
        write_tags(&file, &draft()).unwrap();
        let mut conn = Connection::open_in_memory().unwrap();
        operations::create_tables(&conn).unwrap();
        crate::database::migrations::migrate_enrichment(&mut conn).unwrap();
        let metadata =
            crate::metadata::extract_metadata_blocking(file.to_str().unwrap(), &dir).unwrap();
        operations::persist_metadata(&conn, vec![metadata], vec![1]).unwrap();
        (conn, dir, file)
    }

    #[test]
    fn hybrid_save_updates_tags_index_search_and_undo_restores_bytes() {
        let (conn, dir, file) = fixture();
        let original = fs::read(&file).unwrap();
        let initial = info(&conn, 1).unwrap();
        let mut edit = initial.metadata.clone();
        edit.title = "Renamed title".into();
        edit.artist = "New Artist".into();
        edit.album = "New Album".into();
        edit.genre = "Jazz".into();
        edit.composer = "New Composer".into();
        edit.comment = "New comment".into();
        edit.year = Some(2025);
        edit.track_number = Some(2);
        let saved = save(&conn, 1, edit.clone(), true, &dir.join("backups")).unwrap();
        assert_eq!(saved.track.id, initial.track.id);
        assert_eq!(saved.track.title, "Renamed title");
        assert!(saved.can_undo);
        let parsed = lofty::read_from_path(&file).unwrap();
        assert_eq!(
            parsed.primary_tag().unwrap().title().as_deref(),
            Some("Renamed title")
        );
        let extracted =
            crate::metadata::extract_metadata_blocking(file.to_str().unwrap(), &dir).unwrap();
        assert_eq!(from_extracted(&extracted), edit);
        assert_eq!(
            operations::search_library(&conn, "Renamed")
                .unwrap()
                .tracks
                .len(),
            1
        );
        let reverted = undo(&conn, 1).unwrap();
        assert_eq!(reverted.metadata, initial.metadata);
        assert_eq!(fs::read(&file).unwrap(), original);
        assert!(!reverted.can_undo);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn database_only_edit_survives_rescan_without_touching_file() {
        let (conn, dir, file) = fixture();
        let original = fs::read(&file).unwrap();
        let mut edit = info(&conn, 1).unwrap().metadata;
        edit.title = "Local override".into();
        save(&conn, 1, edit, false, &dir.join("backups")).unwrap();
        assert_eq!(fs::read(&file).unwrap(), original);
        let metadata =
            crate::metadata::extract_metadata_blocking(file.to_str().unwrap(), &dir).unwrap();
        operations::persist_metadata(&conn, vec![metadata], vec![2]).unwrap();
        assert_eq!(info(&conn, 1).unwrap().track.title, "Local override");
        undo(&conn, 1).unwrap();
        assert_eq!(info(&conn, 1).unwrap().track.title, "Original");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn failed_file_write_is_journaled_and_leaves_index_unchanged() {
        let (conn, dir, file) = fixture();
        let initial = info(&conn, 1).unwrap();
        fs::remove_file(file).unwrap();
        let mut edit = initial.metadata.clone();
        edit.title = "Must not persist".into();
        assert!(save(&conn, 1, edit, true, &dir.join("backups")).is_err());
        assert_eq!(info(&conn, 1).unwrap().metadata, initial.metadata);
        let status: String = conn
            .query_row("SELECT status FROM track_metadata_changes", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(status, "failed");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn invalid_edit_creates_no_journal_or_mutation() {
        let (conn, dir, file) = fixture();
        let original = fs::read(&file).unwrap();
        let mut edit = draft();
        edit.track_number = Some(256);
        assert!(save(&conn, 1, edit, true, &dir.join("backups")).is_err());
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM track_metadata_changes", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(count, 0);
        assert_eq!(fs::read(file).unwrap(), original);
        fs::remove_dir_all(dir).unwrap();
    }
}
