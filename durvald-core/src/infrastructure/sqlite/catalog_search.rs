//! SQLite-backed catalog search.

use std::sync::Arc;

use crate::{
    database::models::{ArtistItem, Playlist, Releases},
    domain::catalog::CatalogTrack,
    infrastructure::sqlite::catalog_track::track_from_row,
};

type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;

pub(crate) struct CatalogSearchResults {
    pub(crate) tracks: Vec<CatalogTrack>,
    pub(crate) releases: Vec<Releases>,
    pub(crate) artists: Vec<ArtistItem>,
    pub(crate) playlists: Vec<Playlist>,
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
                    releases: results.releases,
                    artists: results.artists,
                    playlists: results.playlists,
                })
                .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| format!("Blocking database task failed: {error}"))?
    }
}
