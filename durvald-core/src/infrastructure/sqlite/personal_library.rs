//! Named persistence operations for personal library features.
//! Connections and blocking execution stay private to this adapter.
use crate::api::*;
use std::sync::Arc;
type DatabasePool = r2d2::Pool<r2d2_sqlite::SqliteConnectionManager>;
pub(crate) struct SqlitePersonalLibraryRepository {
    db_pool: Arc<DatabasePool>,
}

impl SqlitePersonalLibraryRepository {
    pub(crate) fn new(db_pool: Arc<DatabasePool>) -> Self {
        Self { db_pool }
    }
    pub(crate) async fn local_recommendations(
        &self,
        limit: u32,
    ) -> CoreResult<LocalRecommendations> {
        self.run(move |c| {
            crate::database::recommendations::generate(c, limit, chrono::Utc::now().timestamp())
        })
        .await
    }

    pub(crate) async fn dismiss_local_recommendation(&self, release_id: i64) -> CoreResult<()> {
        self.run(move |c| {
            crate::database::recommendations::dismiss(c, release_id, chrono::Utc::now().timestamp())
        })
        .await
    }

    pub(crate) async fn restore_local_recommendations(&self) -> CoreResult<()> {
        self.run(crate::database::recommendations::restore).await
    }

    pub(crate) async fn record_recommendation_event(
        &self,
        release_id: i64,
        event: RecommendationEvent,
    ) -> CoreResult<()> {
        self.run(move |c| {
            crate::database::recommendations::record(
                c,
                release_id,
                event,
                chrono::Utc::now().timestamp(),
            )
        })
        .await
    }

    pub(crate) async fn recommendation_metrics(&self) -> CoreResult<RecommendationMetrics> {
        self.run(move |c| {
            crate::database::recommendations::metrics(c, chrono::Utc::now().timestamp())
        })
        .await
    }

    pub(crate) async fn followed_artists(&self) -> CoreResult<Vec<FollowedArtist>> {
        self.run(crate::database::artist_news::followed).await
    }

    pub(crate) async fn import_followed_artists(&self, artist_ids: Vec<i64>) -> CoreResult<()> {
        self.run(move |c| {
            crate::database::artist_news::import_legacy(
                c,
                artist_ids,
                chrono::Utc::now().timestamp(),
            )
        })
        .await
    }

    pub(crate) async fn set_artist_followed(
        &self,
        artist_id: i64,
        followed: bool,
    ) -> CoreResult<()> {
        self.run(move |c| {
            crate::database::artist_news::set_follow(
                c,
                artist_id,
                followed,
                chrono::Utc::now().timestamp(),
            )
        })
        .await
    }

    pub(crate) async fn artist_news(&self, query: ArtistNewsQuery) -> CoreResult<ArtistNewsPage> {
        self.run(move |c| {
            crate::database::artist_news::page(c, query, chrono::Utc::now().timestamp())
        })
        .await
    }

    pub(crate) async fn set_artist_news_seen(
        &self,
        release_group_mbid: String,
        seen: bool,
    ) -> CoreResult<()> {
        self.run(move |c| {
            crate::database::artist_news::set_seen(
                c,
                release_group_mbid,
                seen,
                chrono::Utc::now().timestamp(),
            )
        })
        .await
    }

    pub(crate) async fn album_collections(&self) -> CoreResult<Vec<AlbumCollection>> {
        self.run(crate::database::album_collections::list).await
    }

    pub(crate) async fn album_collection(
        &self,
        collection_id: i64,
    ) -> CoreResult<AlbumCollectionPage> {
        self.run(move |c| crate::database::album_collections::page(c, collection_id))
            .await
    }

    pub(crate) async fn save_album_collection(
        &self,
        collection_id: Option<i64>,
        name: String,
        description: String,
        definition: Option<AlbumCollectionDefinition>,
    ) -> CoreResult<AlbumCollection> {
        self.run(move |c| {
            crate::database::album_collections::save(
                c,
                collection_id,
                name,
                description,
                definition,
            )
        })
        .await
    }

    pub(crate) async fn delete_album_collection(&self, collection_id: i64) -> CoreResult<()> {
        self.run(move |c| crate::database::album_collections::delete(c, collection_id))
            .await
    }

    pub(crate) async fn add_album_to_collection(
        &self,
        collection_id: i64,
        release_id: i64,
    ) -> CoreResult<()> {
        self.run(move |c| crate::database::album_collections::add(c, collection_id, release_id))
            .await
    }

    pub(crate) async fn remove_album_from_collection(
        &self,
        collection_id: i64,
        item_id: i64,
    ) -> CoreResult<()> {
        self.run(move |c| crate::database::album_collections::remove(c, collection_id, item_id))
            .await
    }

    pub(crate) async fn reorder_album_collection(
        &self,
        collection_id: i64,
        item_ids: Vec<i64>,
    ) -> CoreResult<()> {
        self.run(move |c| crate::database::album_collections::reorder(c, collection_id, item_ids))
            .await
    }

    pub(crate) async fn album_collection_tracks(
        &self,
        collection_id: i64,
    ) -> CoreResult<Vec<Track>> {
        self.run(move |c| crate::database::album_collections::tracks(c, collection_id))
            .await
    }

    pub(crate) async fn classification_terms(&self) -> CoreResult<Vec<ClassificationTerm>> {
        self.run(crate::database::classification::terms).await
    }

    pub(crate) async fn classification_links(
        &self,
        target: ClassificationTarget,
        id: i64,
    ) -> CoreResult<Vec<ClassificationLink>> {
        self.run(move |c| crate::database::classification::links(c, target, id))
            .await
    }

    pub(crate) async fn classification_page(
        &self,
        kind: ClassificationKind,
        id: i64,
        query: String,
        offset: u64,
        page_size: u64,
    ) -> CoreResult<ClassificationPage> {
        self.run(move |c| {
            crate::database::classification::page(c, kind, id, query, offset, page_size)
        })
        .await
    }

    pub(crate) async fn classification_tracks(
        &self,
        kind: ClassificationKind,
        id: i64,
        query: String,
    ) -> CoreResult<Vec<Track>> {
        self.run(move |c| crate::database::classification::tracks(c, kind, id, query))
            .await
    }

    pub(crate) async fn set_classification(
        &self,
        target: ClassificationTarget,
        id: i64,
        kind: ClassificationKind,
        names: Option<Vec<String>>,
    ) -> CoreResult<()> {
        self.run(move |c| crate::database::classification::set(c, target, id, kind, names))
            .await
    }

    pub(crate) async fn set_style_genres(
        &self,
        style_id: i64,
        genre_ids: Vec<i64>,
    ) -> CoreResult<()> {
        self.run(move |c| crate::database::classification::set_relations(c, style_id, genre_ids))
            .await
    }

    pub(crate) async fn listen_list(&self) -> CoreResult<Vec<ListenListEntry>> {
        self.run(crate::database::listen_list::list).await
    }

    pub(crate) async fn add_release_to_listen_list(
        &self,
        release_id: i64,
    ) -> CoreResult<ListenListEntry> {
        self.run(move |c| crate::database::listen_list::add_local(c, release_id))
            .await
    }

    pub(crate) async fn add_external_to_listen_list(
        &self,
        artist_id: i64,
        release: ExternalReleaseGroup,
    ) -> CoreResult<ListenListEntry> {
        self.run(move |c| crate::database::listen_list::add_external(c, artist_id, release))
            .await
    }

    pub(crate) async fn set_listen_list_heard(&self, entry_id: i64, heard: bool) -> CoreResult<()> {
        self.run(move |c| crate::database::listen_list::set_heard(c, entry_id, heard))
            .await
    }

    pub(crate) async fn remove_from_listen_list(&self, entry_id: i64) -> CoreResult<()> {
        self.run(move |c| crate::database::listen_list::remove(c, entry_id))
            .await
    }

    pub(crate) async fn user_tag_library(&self) -> CoreResult<UserTagLibrary> {
        self.run(crate::database::user_tags::library).await
    }

    pub(crate) async fn create_user_tag(&self, name: String) -> CoreResult<UserTag> {
        self.run(move |c| crate::database::user_tags::create(c, name))
            .await
    }

    pub(crate) async fn rename_user_tag(&self, tag_id: i64, name: String) -> CoreResult<UserTag> {
        self.run(move |c| crate::database::user_tags::rename(c, tag_id, name))
            .await
    }

    pub(crate) async fn delete_user_tag(&self, tag_id: i64) -> CoreResult<()> {
        self.run(move |c| crate::database::user_tags::delete(c, tag_id))
            .await
    }

    pub(crate) async fn update_user_tag_links(
        &self,
        tag_id: i64,
        track_ids: Vec<i64>,
        release_ids: Vec<i64>,
        attached: bool,
    ) -> CoreResult<()> {
        self.run(move |c| {
            crate::database::user_tags::update_links(c, tag_id, track_ids, release_ids, attached)
        })
        .await
    }

    pub(crate) async fn filter_user_tag_items(
        &self,
        tag_ids: Vec<i64>,
        match_all: bool,
        releases: bool,
    ) -> CoreResult<Vec<i64>> {
        self.run(move |c| {
            crate::database::user_tags::matching_items(c, tag_ids, match_all, releases)
        })
        .await
    }
    pub(crate) async fn clear_artist_news_provider(&self) -> CoreResult<()> {
        self.run(crate::database::artist_news::clear_provider).await
    }
    pub(crate) async fn artist_news_refresh_current(
        &self,
        id: i64,
        generation: u64,
        identity_generation: u64,
    ) -> CoreResult<bool> {
        self.run(move |c| {
            crate::database::artist_news::current(c, id, generation, identity_generation)
        })
        .await
    }
    pub(crate) async fn finish_artist_news_refresh(
        &self,
        id: i64,
        generation: u64,
        identity_generation: u64,
        status: ArtistRefreshStatus,
        retry: Option<u64>,
    ) -> CoreResult<bool> {
        self.run(move |c| {
            crate::database::artist_news::finish(
                c,
                id,
                generation,
                identity_generation,
                status,
                retry,
                chrono::Utc::now().timestamp(),
            )
        })
        .await
    }
    async fn run<T, F>(&self, operation: F) -> CoreResult<T>
    where
        T: Send + 'static,
        F: FnOnce(&rusqlite::Connection) -> CoreResult<T> + Send + 'static,
    {
        let pool = self.db_pool.clone();
        tokio::task::spawn_blocking(move || {
            let conn = pool
                .get()
                .map_err(|e| crate::database::storage_error("Personal tags pool", e))?;
            operation(&conn)
        })
        .await
        .map_err(|e| crate::database::storage_error("Personal tags task", e))?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn named_news_operations_reject_stale_refresh_after_unfollow_and_refollow() {
        let manager = r2d2_sqlite::SqliteConnectionManager::memory();
        let pool = Arc::new(r2d2::Pool::builder().max_size(1).build(manager).unwrap());
        {
            let mut conn = pool.get().unwrap();
            crate::database::operations::create_tables(&conn).unwrap();
            crate::database::migrations::migrate_enrichment(&mut conn).unwrap();
            conn.execute("INSERT INTO artists(artist_id,name) VALUES(7,'Artist')", [])
                .unwrap();
        }
        let repo = SqlitePersonalLibraryRepository::new(pool);
        repo.set_artist_followed(7, true).await.unwrap();
        let followed = repo.followed_artists().await.unwrap().remove(0);
        let token = followed.generation;
        let identity = followed.identity.generation;
        assert!(
            repo.artist_news_refresh_current(7, token, identity)
                .await
                .unwrap()
        );
        assert!(
            repo.finish_artist_news_refresh(
                7,
                token,
                identity,
                ArtistRefreshStatus::RateLimited,
                Some(3600)
            )
            .await
            .unwrap()
        );
        let refreshed = repo.followed_artists().await.unwrap().remove(0);
        assert_eq!(
            refreshed.next_refresh_at.unwrap() - refreshed.last_checked_at.unwrap(),
            3600
        );
        repo.set_artist_followed(7, false).await.unwrap();
        assert!(
            !repo
                .artist_news_refresh_current(7, token, identity)
                .await
                .unwrap()
        );
        assert!(
            !repo
                .finish_artist_news_refresh(7, token, identity, ArtistRefreshStatus::Updated, None)
                .await
                .unwrap()
        );
        repo.set_artist_followed(7, true).await.unwrap();
        assert!(
            !repo
                .artist_news_refresh_current(7, token, identity)
                .await
                .unwrap()
        );
        repo.clear_artist_news_provider().await.unwrap();
        assert_eq!(repo.followed_artists().await.unwrap().len(), 1);
    }
}
