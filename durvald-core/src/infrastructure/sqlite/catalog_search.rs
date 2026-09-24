//! SQLite-backed catalog search.

use std::sync::Arc;

use crate::{
    domain::catalog::{CatalogArtist, CatalogRelease, CatalogTrack},
    domain::playlist::PlaylistDetails,
    infrastructure::sqlite::catalog_artist::artist_from_row,
    infrastructure::sqlite::catalog_release::release_from_row,
    infrastructure::sqlite::catalog_track::track_from_row,
    infrastructure::sqlite::playlists::playlist_from_row,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct CatalogSearchResults {
    pub(crate) tracks: Vec<CatalogTrack>,
    pub(crate) releases: Vec<CatalogRelease>,
    pub(crate) artists: Vec<CatalogArtist>,
    pub(crate) playlists: Vec<PlaylistDetails>,
}

pub(crate) struct SqliteCatalogSearchQuery {
    db_pool: Arc<DatabasePool>,
}

impl SqliteCatalogSearchQuery {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }

    pub(crate) async fn search(&self, query: String) -> Result<CatalogSearchResults, String> {
        let db_pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get().map_err(|error| error.to_string())?;
            crate::database::operations::search_library(&conn, &query)
                .map(|results| CatalogSearchResults {
                    tracks: results.tracks.into_iter().map(track_from_row).collect(),
                    releases: results.releases.into_iter().map(release_from_row).collect(),
                    artists: results.artists.into_iter().map(artist_from_row).collect(),
                    playlists: results
                        .playlists
                        .into_iter()
                        .map(playlist_from_row)
                        .collect(),
                })
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Blocking database task failed: {error}"))?
    }
}
