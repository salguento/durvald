//! Playlist use-case coordination.

use base64::Engine;

use crate::{
    api::{CoreError, CoreResult, Playlist, PlaylistTrack, SmartPlaylistDefinition, Track},
    application::library::track_from_catalog,
    domain::ids::{PlaylistId, TrackId},
    domain::playlist::PlaylistDetails,
    infrastructure::sqlite::playlists::{
        PlaylistLookupError, PlaylistMutationError, SqlitePlaylistRepository,
    },
};

pub(crate) struct PlaylistApplication {
    repository: SqlitePlaylistRepository,
}

impl PlaylistApplication {
    pub(crate) fn new(repository: SqlitePlaylistRepository) -> Self {
        Self { repository }
    }

    pub(crate) async fn playlists(&self) -> CoreResult<Vec<Playlist>> {
        self.repository
            .all()
            .await
            .map(|summaries| {
                summaries
                    .into_iter()
                    .map(|summary| playlist_from_domain(summary.playlist, summary.track_count))
                    .collect()
            })
            .map_err(|message| CoreError::Storage { message })
    }

    pub(crate) async fn create_playlist(
        &self,
        name: String,
        description: String,
        artwork_base64: Option<String>,
    ) -> CoreResult<Playlist> {
        if name.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Playlist name cannot be empty".to_string(),
            });
        }
        self.repository
            .create(name, artwork_base64.unwrap_or_default(), description)
            .await
            .map(|playlist| playlist_from_domain(playlist, 0))
            .map_err(|message| CoreError::Storage { message })
    }

    pub(crate) async fn create_smart_playlist(
        &self,
        name: String,
        description: String,
        definition: SmartPlaylistDefinition,
    ) -> CoreResult<Playlist> {
        validate_smart_definition(&name, &definition)?;
        let created = self
            .repository
            .create_smart(name, description, definition)
            .await
            .map_err(|message| CoreError::Storage { message })?;
        self.repository
            .find(created.id)
            .await
            .map(|summary| playlist_from_domain(summary.playlist, summary.track_count))
            .map_err(|error| playlist_lookup_error(error, created.id))
    }

    pub(crate) async fn update_smart_playlist(
        &self,
        playlist_id: PlaylistId,
        name: String,
        description: String,
        definition: SmartPlaylistDefinition,
    ) -> CoreResult<()> {
        validate_smart_definition(&name, &definition)?;
        self.repository
            .update_smart(playlist_id, name, description, definition)
            .await
            .map_err(|error| playlist_mutation_error(error, playlist_id))
    }

    pub(crate) async fn playlist(&self, playlist_id: PlaylistId) -> CoreResult<Playlist> {
        self.repository
            .find(playlist_id)
            .await
            .map(|summary| playlist_from_domain(summary.playlist, summary.track_count))
            .map_err(|error| playlist_lookup_error(error, playlist_id))
    }

    pub(crate) async fn update_playlist(
        &self,
        playlist_id: PlaylistId,
        name: String,
        description: String,
        artwork_base64: Option<String>,
    ) -> CoreResult<()> {
        if name.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: "Playlist name cannot be empty".to_string(),
            });
        }
        self.repository
            .update(
                playlist_id,
                name,
                description,
                artwork_base64.unwrap_or_default(),
            )
            .await
            .map_err(|error| playlist_mutation_error(error, playlist_id))
    }

    pub(crate) async fn delete_playlist(&self, playlist_id: PlaylistId) -> CoreResult<()> {
        self.repository
            .delete(playlist_id)
            .await
            .map_err(|error| playlist_mutation_error(error, playlist_id))
    }

    pub(crate) async fn set_playlist_favorite(
        &self,
        playlist_id: PlaylistId,
        favorite: bool,
    ) -> CoreResult<()> {
        self.repository
            .set_favorite(playlist_id, favorite)
            .await
            .map_err(|error| playlist_mutation_error(error, playlist_id))
    }

    pub(crate) async fn set_playlist_suggest_less(
        &self,
        playlist_id: PlaylistId,
        suggest_less: bool,
    ) -> CoreResult<()> {
        self.repository
            .set_suggest_less(playlist_id, suggest_less)
            .await
            .map_err(|error| playlist_mutation_error(error, playlist_id))
    }

    pub(crate) async fn playlist_tracks(&self, playlist_id: PlaylistId) -> CoreResult<Vec<Track>> {
        self.repository
            .tracks(playlist_id)
            .await
            .map(|tracks| tracks.into_iter().map(track_from_catalog).collect())
            .map_err(|message| CoreError::Storage { message })
    }

    pub(crate) async fn add_track_to_playlist(
        &self,
        playlist_id: PlaylistId,
        track_id: TrackId,
        position: u64,
    ) -> CoreResult<PlaylistTrack> {
        self.repository
            .add_track(playlist_id, track_id, position)
            .await
            .map(|entry| PlaylistTrack {
                playlist_id: entry.playlist_id.get() as i64,
                track_id: entry.track_id.get() as i64,
                position: entry.position,
                added_at: entry.added_at,
            })
            .map_err(|message| CoreError::Storage { message })
    }

    pub(crate) async fn remove_track_from_playlist(
        &self,
        playlist_id: PlaylistId,
        track_id: TrackId,
        position: u64,
    ) -> CoreResult<()> {
        self.repository
            .remove_track(playlist_id, track_id, position)
            .await
            .map_err(|message| CoreError::Storage { message })
    }

    pub(crate) async fn move_playlist_track(
        &self,
        playlist_id: PlaylistId,
        from: u64,
        to: u64,
    ) -> CoreResult<()> {
        self.repository
            .move_track(playlist_id, from, to)
            .await
            .map_err(|message| CoreError::Storage { message })
    }

    pub(crate) async fn playlist_artwork_bytes(
        &self,
        playlist_id: PlaylistId,
    ) -> CoreResult<Option<Vec<u8>>> {
        self.repository
            .artwork(playlist_id)
            .await
            .map_err(|message| CoreError::Storage { message })
    }
}

fn playlist_from_domain(playlist: PlaylistDetails, track_count: u64) -> Playlist {
    Playlist {
        id: playlist.id.get() as i64,
        name: playlist.name,
        description: playlist.description,
        artwork_id: playlist
            .artwork
            .map(|cover| base64::engine::general_purpose::STANDARD.encode(cover)),
        is_favorite: playlist.is_favorite,
        suggest_less: playlist.suggest_less,
        track_count,
        created_at: playlist.created_at,
        updated_at: playlist.updated_at,
        is_smart: playlist.smart_definition.is_some(),
        smart_definition: playlist.smart_definition,
    }
}

fn validate_smart_definition(name: &str, definition: &SmartPlaylistDefinition) -> CoreResult<()> {
    if name.trim().is_empty() {
        return Err(CoreError::InvalidInput {
            message: "Playlist name cannot be empty".into(),
        });
    }
    crate::database::operations::validate_smart_playlist_definition(definition)
        .map_err(|message| CoreError::InvalidInput { message })
}

fn playlist_lookup_error(error: PlaylistLookupError, playlist_id: PlaylistId) -> CoreError {
    match error {
        PlaylistLookupError::NotFound => CoreError::NotFound {
            message: format!("Playlist {} not found", playlist_id.get()),
        },
        PlaylistLookupError::Storage(message) => CoreError::Storage { message },
    }
}

fn playlist_mutation_error(error: PlaylistMutationError, playlist_id: PlaylistId) -> CoreError {
    match error {
        PlaylistMutationError::NotFound => CoreError::NotFound {
            message: format!("Playlist {} not found", playlist_id.get()),
        },
        PlaylistMutationError::Storage(message) => CoreError::Storage { message },
    }
}
