# Referência da API pública do core

Snapshot: 29/10/2026, árvore de trabalho. Anexo do [guia de arquitetura](guia-arquitetura-core.md).

Este índice foi extraído das declarações do código: **205 métodos em `DurvaldCore`,
13 nos três objetos de sessão, total de 218 métodos**, mais os contratos auxiliares
indicados abaixo. `DurvaldCore::open` está nessa contagem; é associado, sem `self`.
A fábrica FFI livre `open`, o construtor de configuração e o callback não estão
nesses 218. Não confundir quantidade de métodos com quantidade de casos de uso.

As assinaturas são Rust, com whitespace simplificado. Os bindings Swift convertem
nomes/tipos e usam a fábrica própria. `CoreResult<T>` pode falhar; `Option<T>`
representa ausência; páginas/jobs podem trazer `failure` mesmo dentro de `Ok`.
IDs de candidato, ocorrência, geração e revisão têm escopos diferentes, explicados
no guia. Os grupos abaixo organizam consulta, não mudam a propriedade do método.

Nenhum valor real de credencial está neste documento. Parâmetros como `api_key`,
`api_secret` ou `credential` são entradas deliberadas de configuração, não campos
a serem exibidos em logs. As APIs antigas autenticadas continuam existentes.

## DurvaldCore

### Inicialização e diagnóstico

- [open](../src/core.rs#L129) — `async fn open(config: CoreConfig) -> CoreResult<Arc<Self>>`
- [integration_diagnostics](../src/core.rs#L184) — `async fn integration_diagnostics(&self) -> IntegrationDiagnostics`

### Coleções de serviços

- [service_import_settings](../src/core.rs#L231) — `async fn service_import_settings(&self) -> CoreResult<Vec<ServiceImportSettings>>`
- [configure_service_import](../src/core.rs#L234) — `async fn configure_service_import( &self, provider: ServiceProvider, enabled: bool, credential: Option<String>) -> CoreResult<Vec<ServiceImportSettings>>`
- [service_collection_import](../src/core.rs#L244) — `async fn service_collection_import( &self, job_id: String) -> CoreResult<ServiceCollectionJob>`
- [service_collection_imports](../src/core.rs#L254) — `async fn service_collection_imports(&self) -> CoreResult<Vec<ServiceCollectionJob>>`
- [begin_service_collection_import](../src/core.rs#L257) — `async fn begin_service_collection_import( &self, url: String) -> CoreResult<ServiceCollectionJob>`
- [load_service_collection_page](../src/core.rs#L263) — `async fn load_service_collection_page( &self, job_id: String, refresh: bool) -> CoreResult<ServiceCollectionJob>`
- [retry_service_collection_page](../src/core.rs#L270) — `async fn retry_service_collection_page( &self, job_id: String, page_index: u32) -> CoreResult<ServiceCollectionJob>`
- [import_service_collection_items](../src/core.rs#L279) — `async fn import_service_collection_items( &self, job_id: String, occurrence_ids: Vec<String>, confirmed: bool) -> CoreResult<ServiceCollectionJob>`
- [cancel_service_collection_import](../src/core.rs#L289) — `async fn cancel_service_collection_import( &self, job_id: String) -> CoreResult<ServiceCollectionJob>`
- [resume_service_collection_import](../src/core.rs#L295) — `async fn resume_service_collection_import( &self, job_id: String) -> CoreResult<ServiceCollectionJob>`

### Transferência e importação de arquivos

- [download_transfer_settings](../src/core.rs#L301) — `async fn download_transfer_settings(&self) -> CoreResult<DownloadTransferSettings>`
- [configure_download_transfers](../src/core.rs#L304) — `async fn configure_download_transfers( &self, settings: DownloadTransferSettings) -> CoreResult<DownloadTransferSettings>`
- [download_transfers](../src/core.rs#L310) — `async fn download_transfers(&self) -> CoreResult<Vec<DownloadTransferJob>>`
- [refresh_download_transfer](../src/core.rs#L313) — `async fn refresh_download_transfer( &self, job_id: String) -> CoreResult<DownloadTransferJob>`
- [cancel_download_transfer](../src/core.rs#L319) — `async fn cancel_download_transfer( &self, job_id: String) -> CoreResult<DownloadTransferJob>`
- [retry_download_transfer](../src/core.rs#L325) — `async fn retry_download_transfer(&self, job_id: String) -> CoreResult<DownloadTransferJob>`
- [pending_download_import](../src/core.rs#L328) — `async fn pending_download_import( &self, job_id: String, file_index: u32) -> CoreResult<DownloadImportPreview>`
- [inspect_download_file](../src/core.rs#L337) — `async fn inspect_download_file( &self, job_id: String, file_index: u32, path: String) -> CoreResult<DownloadImportPreview>`
- [import_download_file](../src/core.rs#L347) — `async fn import_download_file( &self, job_id: String, file_index: u32, review_token: String, target_track_id: Option<i64>, confirmed: bool) -> CoreResult<DownloadTransferJob>`

### Pesquisa de downloads

- [download_search_settings](../src/core.rs#L359) — `async fn download_search_settings(&self) -> CoreResult<DownloadSearchSettings>`
- [configure_download_search](../src/core.rs#L362) — `async fn configure_download_search( &self, endpoint: String, api_key: Option<String>, enabled: bool, sharing_acknowledged: bool) -> CoreResult<DownloadSearchSettings>`
- [download_search_session](../src/core.rs#L373) — `fn download_search_session(&self) -> Arc<DownloadSearchSession>`

### Player incorporado e entrada de links

- [set_embedded_playback_host](../src/core.rs#L193) — `async fn set_embedded_playback_host( &self, host: Box<dyn EmbeddedPlaybackHost>) -> CoreResult<()>`
- [detach_embedded_playback_host](../src/core.rs#L199) — `async fn detach_embedded_playback_host(&self) -> CoreResult<()>`
- [embedded_playback](../src/core.rs#L202) — `async fn embedded_playback(&self) -> Option<EmbeddedPlaybackSnapshot>`
- [play_embedded_track_source](../src/core.rs#L205) — `async fn play_embedded_track_source( &self, track_id: i64, source_id: i64) -> CoreResult<PlaybackSnapshot>`
- [report_embedded_playback_event](../src/core.rs#L214) — `async fn report_embedded_playback_event( &self, event: EmbeddedPlaybackEvent) -> CoreResult<()>`
- [youtube_playback_enabled](../src/core.rs#L221) — `async fn youtube_playback_enabled(&self) -> bool`
- [set_youtube_playback_enabled](../src/core.rs#L226) — `async fn set_youtube_playback_enabled(&self, enabled: bool) -> CoreResult<()>`
- [resolve_soundcloud_link_entry](../src/core.rs#L381) — `async fn resolve_soundcloud_link_entry( &self, url: String, title: String, artist: Option<String>) -> CoreResult<CatalogEntry>`
- [soundcloud_link_entry](../src/core.rs#L391) — `fn soundcloud_link_entry( &self, url: String, title: String, artist: Option<String>) -> CoreResult<CatalogEntry>`
- [soundcloud_playback_enabled](../src/core.rs#L399) — `async fn soundcloud_playback_enabled(&self) -> bool`
- [set_soundcloud_playback_enabled](../src/core.rs#L402) — `async fn set_soundcloud_playback_enabled(&self, enabled: bool) -> CoreResult<()>`
- [playback_source_status](../src/core.rs#L407) — `async fn playback_source_status(&self) -> Option<PlaybackSourceStatus>`
- [save_listening_source](../src/core.rs#L410) — `async fn save_listening_source( &self, generation: String, track_id: Option<i64>, confirmed: bool) -> CoreResult<TrackSource>`

### Descoberta e gestão de origens

- [source_search_session](../src/core.rs#L420) — `fn source_search_session(&self) -> Arc<SourceSearchSession>`
- [source_providers](../src/core.rs#L427) — `async fn source_providers(&self) -> CoreResult<Vec<SourceProvider>>`
- [set_source_provider_enabled](../src/core.rs#L430) — `async fn set_source_provider_enabled( &self, provider: String, enabled: bool) -> CoreResult<()>`
- [track_sources](../src/core.rs#L437) — `async fn track_sources(&self, track_id: i64) -> CoreResult<Vec<TrackSource>>`
- [test_track_source](../src/core.rs#L440) — `async fn test_track_source( &self, track_id: i64, source_id: i64) -> CoreResult<SourceTestResult>`
- [set_track_source_enabled](../src/core.rs#L447) — `async fn set_track_source_enabled( &self, track_id: i64, source_id: i64, enabled: bool) -> CoreResult<TrackSource>`
- [remove_track_source](../src/core.rs#L455) — `async fn remove_track_source(&self, track_id: i64, source_id: i64) -> CoreResult<()>`
- [prefer_track_source](../src/core.rs#L458) — `async fn prefer_track_source( &self, track_id: i64, source_id: Option<i64>) -> CoreResult<()>`
- [attach_local_track_source](../src/core.rs#L465) — `async fn attach_local_track_source( &self, track_id: i64, path: String) -> CoreResult<TrackSource>`
- [track_source_open_url](../src/core.rs#L472) — `async fn track_source_open_url(&self, track_id: i64, source_id: i64) -> CoreResult<String>`
- [play_track_source](../src/core.rs#L475) — `async fn play_track_source( &self, track_id: i64, source_id: i64) -> CoreResult<PlaybackSnapshot>`

### Catálogo externo e seleções

- [catalog_search_session](../src/core.rs#L485) — `fn catalog_search_session(&self) -> Arc<CatalogSearchSession>`
- [catalog_selection](../src/core.rs#L492) — `async fn catalog_selection( &self, reference: CatalogReference) -> CoreResult<Option<CatalogSelection>>`
- [catalog_selections](../src/core.rs#L498) — `async fn catalog_selections(&self) -> CoreResult<Vec<CatalogSelection>>`
- [save_remote_track](../src/core.rs#L502) — `async fn save_remote_track(&self, entry: CatalogEntry) -> CoreResult<Track>`
- [save_catalog_selection](../src/core.rs#L506) — `async fn save_catalog_selection( &self, entry: CatalogEntry) -> CoreResult<CatalogSelection>`
- [follow_catalog_artist](../src/core.rs#L512) — `async fn follow_catalog_artist( &self, entry: CatalogEntry, followed: bool) -> CoreResult<CatalogSelection>`
- [add_catalog_to_listen_list](../src/core.rs#L519) — `async fn add_catalog_to_listen_list( &self, entry: CatalogEntry, artist: CatalogEntry) -> CoreResult<ListenListEntry>`
- [set_catalog_provider_enabled](../src/core.rs#L526) — `async fn set_catalog_provider_enabled(&self, enabled: bool) -> CoreResult<bool>`

### Enriquecimento, identidade e novidades

- [materialize_remote_artist](../src/core.rs#L630) — `async fn materialize_remote_artist( &self, selection: RemoteArtistSelection) -> CoreResult<Artist>`
- [artist_details](../src/core.rs#L641) — `async fn artist_details( &self, artist_id: i64, language: String) -> CoreResult<ArtistDetails>`
- [artist_discography](../src/core.rs#L652) — `async fn artist_discography( &self, artist_id: i64, page_size: u64, offset: u64) -> CoreResult<ArtistDiscographyPage>`
- [followed_artists](../src/core.rs#L663) — `async fn followed_artists(&self) -> CoreResult<Vec<FollowedArtist>>`
- [import_followed_artists](../src/core.rs#L666) — `async fn import_followed_artists(&self, artist_ids: Vec<i64>) -> CoreResult<()>`
- [set_artist_followed](../src/core.rs#L671) — `async fn set_artist_followed(&self, artist_id: i64, followed: bool) -> CoreResult<()>`
- [artist_news](../src/core.rs#L677) — `async fn artist_news(&self, query: ArtistNewsQuery) -> CoreResult<ArtistNewsPage>`
- [set_artist_news_seen](../src/core.rs#L680) — `async fn set_artist_news_seen( &self, release_group_mbid: String, seen: bool) -> CoreResult<()>`
- [refresh_artist_news](../src/core.rs#L689) — `async fn refresh_artist_news( &self, artist_id: i64, force: bool) -> CoreResult<ArtistRefreshResult>`
- [artist_popular_tracks](../src/core.rs#L700) — `async fn artist_popular_tracks( &self, artist_id: i64) -> CoreResult<Option<ArtistPopularTracks>>`
- [external_release_details](../src/core.rs#L710) — `async fn external_release_details( &self, artist_id: i64, release_group_mbid: String) -> CoreResult<ExternalReleaseDetails>`
- [artist_identity](../src/core.rs#L720) — `async fn artist_identity(&self, artist_id: i64) -> CoreResult<ArtistIdentity>`
- [resolve_artist_candidates](../src/core.rs#L726) — `async fn resolve_artist_candidates( &self, artist_id: i64) -> CoreResult<ArtistIdentityCandidates>`
- [confirm_artist_identity](../src/core.rs#L735) — `async fn confirm_artist_identity( &self, artist_id: i64, musicbrainz_id: String) -> CoreResult<ArtistIdentity>`
- [clear_artist_identity](../src/core.rs#L745) — `async fn clear_artist_identity(&self, artist_id: i64) -> CoreResult<()>`
- [enrichment_settings](../src/core.rs#L751) — `async fn enrichment_settings(&self) -> CoreResult<EnrichmentSettings>`
- [configure_enrichment](../src/core.rs#L756) — `async fn configure_enrichment(&self, settings: EnrichmentSettings) -> CoreResult<()>`
- [clear_enrichment_provider_data](../src/core.rs#L762) — `async fn clear_enrichment_provider_data( &self, provider: EnrichmentProvider) -> CoreResult<()>`
- [refresh_artist](../src/core.rs#L773) — `async fn refresh_artist( &self, artist_id: i64, request: ArtistRefreshRequest) -> CoreResult<ArtistRefreshResult>`
- [sync_artist_release_metadata](../src/core.rs#L785) — `async fn sync_artist_release_metadata(&self, artist_id: i64) -> CoreResult<Vec<Release>>`
- [set_artist_override](../src/core.rs#L791) — `async fn set_artist_override( &self, artist_id: i64, value: ArtistFieldOverride) -> CoreResult<()>`
- [clear_artist_override](../src/core.rs#L801) — `async fn clear_artist_override( &self, artist_id: i64, field: ArtistProfileField, language: String) -> CoreResult<()>`

### Playlists e Replay

- [playlists](../src/core.rs#L827) — `async fn playlists(&self) -> CoreResult<Vec<Playlist>>`
- [create_playlist](../src/core.rs#L832) — `async fn create_playlist( &self, name: String, description: String, artwork_base64: Option<String>) -> CoreResult<Playlist>`
- [replay_preview](../src/core.rs#L844) — `async fn replay_preview( &self, request: crate::api::ReplayRequest) -> CoreResult<crate::api::ReplayPreview>`
- [save_replay](../src/core.rs#L852) — `async fn save_replay( &self, request: crate::api::ReplayRequest, name: String, description: String, mode: crate::api::ReplaySaveMode, close_automatically: bool, artwork_base64: Option<String>) -> CoreResult<Playlist>`
- [update_replay](../src/core.rs#L873) — `async fn update_replay( &self, request: crate::api::ReplayRequest, mode: crate::api::ReplaySaveMode, close_automatically: bool) -> CoreResult<Playlist>`
- [create_smart_playlist](../src/core.rs#L885) — `async fn create_smart_playlist( &self, name: String, description: String, definition: SmartPlaylistDefinition) -> CoreResult<Playlist>`
- [update_smart_playlist](../src/core.rs#L897) — `async fn update_smart_playlist( &self, playlist_id: i64, name: String, description: String, definition: SmartPlaylistDefinition) -> CoreResult<()>`
- [playlist](../src/core.rs#L915) — `async fn playlist(&self, playlist_id: i64) -> CoreResult<Playlist>`
- [update_playlist](../src/core.rs#L922) — `async fn update_playlist( &self, playlist_id: i64, name: String, description: String, artwork_base64: Option<String>) -> CoreResult<()>`
- [delete_playlist](../src/core.rs#L940) — `async fn delete_playlist(&self, playlist_id: i64) -> CoreResult<()>`
- [playlist_tracks](../src/core.rs#L947) — `async fn playlist_tracks(&self, playlist_id: i64) -> CoreResult<Vec<Track>>`
- [playlist_artwork_bytes](../src/core.rs#L960) — `async fn playlist_artwork_bytes(&self, playlist_id: i64) -> CoreResult<Option<Vec<u8>>>`
- [set_playlist_favorite](../src/core.rs#L1194) — `async fn set_playlist_favorite(&self, playlist_id: i64, favorite: bool) -> CoreResult<()>`
- [set_playlist_suggest_less](../src/core.rs#L1201) — `async fn set_playlist_suggest_less( &self, playlist_id: i64, suggest_less: bool) -> CoreResult<()>`
- [add_track_to_playlist](../src/core.rs#L1270) — `async fn add_track_to_playlist( &self, playlist_id: i64, track_id: i64, position: u64) -> CoreResult<PlaylistTrack>`
- [remove_track_from_playlist](../src/core.rs#L1286) — `async fn remove_track_from_playlist( &self, playlist_id: i64, track_id: i64, position: u64) -> CoreResult<()>`
- [move_playlist_track](../src/core.rs#L1302) — `async fn move_playlist_track( &self, playlist_id: i64, from: u64, to: u64) -> CoreResult<()>`

### Coleções de álbuns

- [album_collections](../src/core.rs#L967) — `async fn album_collections(&self) -> CoreResult<Vec<AlbumCollection>>`
- [album_collection](../src/core.rs#L970) — `async fn album_collection(&self, collection_id: i64) -> CoreResult<AlbumCollectionPage>`
- [save_album_collection](../src/core.rs#L975) — `async fn save_album_collection( &self, collection_id: Option<i64>, name: String, description: String, definition: Option<AlbumCollectionDefinition>) -> CoreResult<AlbumCollection>`
- [delete_album_collection](../src/core.rs#L986) — `async fn delete_album_collection(&self, collection_id: i64) -> CoreResult<()>`
- [add_album_to_collection](../src/core.rs#L991) — `async fn add_album_to_collection( &self, collection_id: i64, release_id: i64) -> CoreResult<()>`
- [remove_album_from_collection](../src/core.rs#L1000) — `async fn remove_album_from_collection( &self, collection_id: i64, item_id: i64) -> CoreResult<()>`
- [reorder_album_collection](../src/core.rs#L1009) — `async fn reorder_album_collection( &self, collection_id: i64, item_ids: Vec<i64>) -> CoreResult<()>`
- [album_collection_tracks](../src/core.rs#L1018) — `async fn album_collection_tracks(&self, collection_id: i64) -> CoreResult<Vec<Track>>`

### Classificação, Listen List e tags pessoais

- [classification_terms](../src/core.rs#L1025) — `async fn classification_terms(&self) -> CoreResult<Vec<ClassificationTerm>>`
- [classification_links](../src/core.rs#L1028) — `async fn classification_links( &self, target: ClassificationTarget, id: i64) -> CoreResult<Vec<ClassificationLink>>`
- [classification_page](../src/core.rs#L1037) — `async fn classification_page( &self, kind: ClassificationKind, id: i64, query: String, offset: u64, page_size: u64) -> CoreResult<ClassificationPage>`
- [classification_tracks](../src/core.rs#L1049) — `async fn classification_tracks( &self, kind: ClassificationKind, id: i64, query: String) -> CoreResult<Vec<Track>>`
- [set_classification](../src/core.rs#L1060) — `async fn set_classification( &self, target: ClassificationTarget, id: i64, kind: ClassificationKind, names: Option<Vec<String>>) -> CoreResult<()>`
- [set_style_genres](../src/core.rs#L1072) — `async fn set_style_genres(&self, style_id: i64, genre_ids: Vec<i64>) -> CoreResult<()>`
- [listen_list](../src/core.rs#L1079) — `async fn listen_list(&self) -> CoreResult<Vec<ListenListEntry>>`
- [add_release_to_listen_list](../src/core.rs#L1082) — `async fn add_release_to_listen_list(&self, release_id: i64) -> CoreResult<ListenListEntry>`
- [add_external_to_listen_list](../src/core.rs#L1087) — `async fn add_external_to_listen_list( &self, artist_id: i64, release: ExternalReleaseGroup) -> CoreResult<ListenListEntry>`
- [set_listen_list_heard](../src/core.rs#L1096) — `async fn set_listen_list_heard(&self, entry_id: i64, heard: bool) -> CoreResult<()>`
- [remove_from_listen_list](../src/core.rs#L1101) — `async fn remove_from_listen_list(&self, entry_id: i64) -> CoreResult<()>`
- [user_tag_library](../src/core.rs#L1108) — `async fn user_tag_library(&self) -> CoreResult<UserTagLibrary>`
- [create_user_tag](../src/core.rs#L1111) — `async fn create_user_tag(&self, name: String) -> CoreResult<UserTag>`
- [rename_user_tag](../src/core.rs#L1114) — `async fn rename_user_tag(&self, tag_id: i64, name: String) -> CoreResult<UserTag>`
- [delete_user_tag](../src/core.rs#L1117) — `async fn delete_user_tag(&self, tag_id: i64) -> CoreResult<()>`
- [update_user_tag_links](../src/core.rs#L1121) — `async fn update_user_tag_links( &self, tag_id: i64, track_ids: Vec<i64>, release_ids: Vec<i64>, attached: bool) -> CoreResult<()>`
- [filter_user_tag_items](../src/core.rs#L1132) — `async fn filter_user_tag_items( &self, tag_ids: Vec<i64>, match_all: bool, releases: bool) -> CoreResult<Vec<i64>>`

### Preferências pessoais, notas e recomendações

- [local_recommendations](../src/core.rs#L583) — `async fn local_recommendations(&self, limit: u32) -> CoreResult<LocalRecommendations>`
- [dismiss_local_recommendation](../src/core.rs#L586) — `async fn dismiss_local_recommendation(&self, release_id: i64) -> CoreResult<()>`
- [restore_local_recommendations](../src/core.rs#L591) — `async fn restore_local_recommendations(&self) -> CoreResult<()>`
- [record_recommendation_event](../src/core.rs#L596) — `async fn record_recommendation_event( &self, release_id: i64, event: RecommendationEvent) -> CoreResult<()>`
- [recommendation_metrics](../src/core.rs#L605) — `async fn recommendation_metrics(&self) -> CoreResult<RecommendationMetrics>`
- [set_track_favorite](../src/core.rs#L1144) — `async fn set_track_favorite(&self, track_id: i64, favorite: bool) -> CoreResult<()>`
- [set_release_favorite](../src/core.rs#L1151) — `async fn set_release_favorite(&self, release_id: i64, favorite: bool) -> CoreResult<()>`
- [set_track_hidden](../src/core.rs#L1158) — `async fn set_track_hidden(&self, track_id: i64, hidden: bool) -> CoreResult<()>`
- [set_release_hidden](../src/core.rs#L1165) — `async fn set_release_hidden(&self, release_id: i64, hidden: bool) -> CoreResult<()>`
- [set_track_suggest_less](../src/core.rs#L1172) — `async fn set_track_suggest_less( &self, track_id: i64, suggest_less: bool) -> CoreResult<()>`
- [set_release_suggest_less](../src/core.rs#L1183) — `async fn set_release_suggest_less( &self, release_id: i64, suggest_less: bool) -> CoreResult<()>`
- [set_track_rating](../src/core.rs#L1212) — `async fn set_track_rating(&self, track_id: i64, rating: Option<u8>) -> CoreResult<()>`
- [set_release_rating](../src/core.rs#L1223) — `async fn set_release_rating(&self, release_id: i64, rating: Option<u8>) -> CoreResult<()>`
- [set_track_rating_half_steps](../src/core.rs#L1233) — `async fn set_track_rating_half_steps( &self, track_id: i64, rating_half_steps: Option<u8>) -> CoreResult<()>`
- [set_release_rating_half_steps](../src/core.rs#L1242) — `async fn set_release_rating_half_steps( &self, release_id: i64, rating_half_steps: Option<u8>) -> CoreResult<()>`
- [rating_preferences](../src/core.rs#L1251) — `async fn rating_preferences(&self) -> CoreResult<crate::api::RatingScalePreferences>`
- [rating_conversion_preview](../src/core.rs#L1254) — `async fn rating_conversion_preview( &self) -> CoreResult<crate::api::RatingConversionPreview>`
- [update_rating_preferences](../src/core.rs#L1259) — `async fn update_rating_preferences( &self, granularity: crate::api::RatingGranularity, rounding: Option<crate::api::RatingRounding>) -> CoreResult<crate::api::RatingPreferenceChange>`

### Player, fila, sessão e histórico

- [play](../src/core.rs#L1314) — `async fn play(&self, track_id: i64) -> CoreResult<PlaybackSnapshot>`
- [play_with_context](../src/core.rs#L1321) — `async fn play_with_context( &self, track_id: i64, source_context: String) -> CoreResult<PlaybackSnapshot>`
- [add_to_queue_with_context](../src/core.rs#L1332) — `async fn add_to_queue_with_context( &self, track_id: i64, source_context: String) -> CoreResult<()>`
- [play_collection](../src/core.rs#L1344) — `async fn play_collection( &self, track_ids: Vec<i64>, source_contexts: Vec<String>, starting_position: Option<u64>, shuffle_enabled: Option<bool>) -> CoreResult<PlaybackSnapshot>`
- [playback](../src/core.rs#L1362) — `async fn playback(&self) -> PlaybackSnapshot`
- [pause](../src/core.rs#L1380) — `async fn pause(&self) -> CoreResult<()>`
- [resume](../src/core.rs#L1385) — `async fn resume(&self) -> CoreResult<()>`
- [stop](../src/core.rs#L1390) — `async fn stop(&self) -> CoreResult<()>`
- [seek](../src/core.rs#L1395) — `async fn seek(&self, seconds: u64) -> CoreResult<()>`
- [set_volume](../src/core.rs#L1400) — `async fn set_volume(&self, volume: f32) -> CoreResult<()>`
- [set_shuffle_enabled](../src/core.rs#L1405) — `async fn set_shuffle_enabled(&self, enabled: bool) -> CoreResult<PlaybackSnapshot>`
- [set_repeat_mode](../src/core.rs#L1410) — `async fn set_repeat_mode(&self, mode: RepeatMode) -> CoreResult<PlaybackSnapshot>`
- [last_session](../src/core.rs#L1441) — `async fn last_session(&self) -> CoreResult<LastSession>`
- [playback_history_revision](../src/core.rs#L1446) — `async fn playback_history_revision(&self) -> CoreResult<u64>`
- [playback_history](../src/core.rs#L1451) — `async fn playback_history(&self) -> CoreResult<Vec<PlaybackHistoryItem>>`
- [playback_history_page](../src/core.rs#L1456) — `async fn playback_history_page( &self, page_size: u64, offset: u64) -> CoreResult<PlaybackHistoryPage>`
- [remove_playback_history_item](../src/core.rs#L1467) — `async fn remove_playback_history_item(&self, history_id: i64) -> CoreResult<()>`
- [clear_playback_history](../src/core.rs#L1474) — `async fn clear_playback_history(&self) -> CoreResult<u64>`
- [save_session](../src/core.rs#L1479) — `async fn save_session(&self, session: LastSession) -> CoreResult<()>`
- [add_to_queue](../src/core.rs#L1539) — `async fn add_to_queue(&self, track_id: i64) -> CoreResult<()>`
- [next_track](../src/core.rs#L1546) — `async fn next_track(&self) -> CoreResult<PlaybackSnapshot>`
- [previous_track](../src/core.rs#L1551) — `async fn previous_track(&self) -> CoreResult<PlaybackSnapshot>`
- [play_queue_item](../src/core.rs#L1556) — `async fn play_queue_item(&self, position: u64) -> CoreResult<PlaybackSnapshot>`
- [remove_from_queue](../src/core.rs#L1561) — `async fn remove_from_queue(&self, position: u64) -> CoreResult<()>`
- [move_queue_item](../src/core.rs#L1566) — `async fn move_queue_item(&self, from: u64, to: u64) -> CoreResult<()>`
- [clear_queue](../src/core.rs#L1571) — `async fn clear_queue(&self) -> CoreResult<()>`
- [queue](../src/core.rs#L1576) — `async fn queue(&self) -> CoreResult<Vec<QueueItem>>`

### Last.fm

- [lastfm_status](../src/core.rs#L1415) — `async fn lastfm_status(&self) -> CoreResult<LastFmStatus>`
- [configure_lastfm](../src/core.rs#L1420) — `async fn configure_lastfm(&self, api_key: String, api_secret: String) -> CoreResult<()>`
- [lastfm_auth_token](../src/core.rs#L1425) — `async fn lastfm_auth_token(&self) -> CoreResult<AuthTokenResponse>`
- [complete_lastfm_auth](../src/core.rs#L1430) — `async fn complete_lastfm_auth(&self, token: String) -> CoreResult<SessionResponse>`
- [disconnect_lastfm](../src/core.rs#L1436) — `async fn disconnect_lastfm(&self) -> CoreResult<()>`

### Configuração e saída de áudio

- [settings](../src/core.rs#L1484) — `async fn settings(&self) -> CoreResult<Settings>`
- [update_settings](../src/core.rs#L1489) — `async fn update_settings(&self, settings: Settings) -> CoreResult<()>`
- [audio_output_state](../src/core.rs#L1494) — `async fn audio_output_state(&self) -> CoreResult<AudioOutputState>`
- [select_audio_output_device](../src/core.rs#L1499) — `async fn select_audio_output_device( &self, device_id: Option<String>) -> CoreResult<AudioOutputState>`
- [equalizer_metrics](../src/core.rs#L1509) — `async fn equalizer_metrics(&self) -> EqualizerMetrics`
- [set_spectrum_enabled](../src/core.rs#L1518) — `async fn set_spectrum_enabled(&self, enabled: bool)`
- [spectrum_snapshot](../src/core.rs#L1527) — `async fn spectrum_snapshot(&self) -> SpectrumSnapshot`

### Metadata, arte e reparos

- [artwork_bytes](../src/core.rs#L955) — `async fn artwork_bytes(&self, artwork_id: String) -> CoreResult<Option<Vec<u8>>>`
- [track_info](../src/core.rs#L1597) — `async fn track_info(&self, track_id: i64) -> CoreResult<TrackInfo>`
- [track_lyrics](../src/core.rs#L1604) — `async fn track_lyrics(&self, track_id: i64) -> CoreResult<Option<String>>`
- [save_track_metadata](../src/core.rs#L1610) — `async fn save_track_metadata( &self, track_id: i64, metadata: TrackMetadataEdit, write_to_file: bool) -> CoreResult<TrackInfo>`
- [undo_track_metadata](../src/core.rs#L1621) — `async fn undo_track_metadata(&self, track_id: i64) -> CoreResult<TrackInfo>`
- [analyze_library_repairs](../src/core.rs#L1627) — `async fn analyze_library_repairs(&self) -> CoreResult<LibraryRepairAnalysis>`
- [merge_library_records](../src/core.rs#L1631) — `async fn merge_library_records( &self, source_id: i64, target_id: i64, source_is_missing: bool) -> CoreResult<()>`
- [extract_metadata](../src/core.rs#L1662) — `async fn extract_metadata(&self, file_path: String) -> CoreResult<AudioMetadata>`

### Biblioteca, scan e leitura local

- [scan_library](../src/core.rs#L189) — `async fn scan_library(&self, paths: Vec<String>) -> CoreResult<ScanResult>`
- [scan_progress](../src/core.rs#L531) — `fn scan_progress(&self) -> CoreResult<Option<ScanProgress>>`
- [cancel_library_scan](../src/core.rs#L536) — `fn cancel_library_scan(&self) -> CoreResult<()>`
- [add_library_path](../src/core.rs#L541) — `async fn add_library_path(&self, path: String) -> CoreResult<()>`
- [library_paths](../src/core.rs#L546) — `async fn library_paths(&self) -> CoreResult<Vec<String>>`
- [scan_configured_library](../src/core.rs#L551) — `async fn scan_configured_library(&self) -> CoreResult<ScanResult>`
- [remove_library_path](../src/core.rs#L556) — `async fn remove_library_path(&self, path: String) -> CoreResult<()>`
- [search](../src/core.rs#L561) — `async fn search(&self, query: String) -> CoreResult<SearchResults>`
- [tracks_page](../src/core.rs#L566) — `async fn tracks_page(&self, page_size: u64, offset: u64) -> CoreResult<TrackPage>`
- [release_playback_recency](../src/core.rs#L573) — `async fn release_playback_recency(&self) -> CoreResult<Vec<KeyValuePair>>`
- [home_library](../src/core.rs#L578) — `async fn home_library(&self, limit: u64) -> CoreResult<crate::api::HomeLibrary>`
- [releases_page](../src/core.rs#L610) — `async fn releases_page(&self, page_size: u64, offset: u64) -> CoreResult<ReleasePage>`
- [artists](../src/core.rs#L617) — `async fn artists(&self) -> CoreResult<Vec<Artist>>`
- [artist](../src/core.rs#L622) — `async fn artist(&self, artist_id: i64) -> CoreResult<Artist>`
- [artist_releases](../src/core.rs#L813) — `async fn artist_releases(&self, artist_id: i64) -> CoreResult<Vec<Release>>`
- [artist_tracks](../src/core.rs#L820) — `async fn artist_tracks(&self, artist_id: i64) -> CoreResult<Vec<Track>>`
- [tracks_by_ids](../src/core.rs#L1581) — `async fn tracks_by_ids(&self, track_ids: Vec<i64>) -> CoreResult<Vec<Track>>`
- [track](../src/core.rs#L1590) — `async fn track(&self, track_id: i64) -> CoreResult<Track>`
- [release](../src/core.rs#L1648) — `async fn release(&self, release_id: i64) -> CoreResult<Release>`
- [release_tracks](../src/core.rs#L1655) — `async fn release_tracks(&self, release_id: i64) -> CoreResult<Vec<Track>>`

## CatalogSearchSession

- [detail_section](../src/core.rs#L1731) — `async fn detail_section( &self, request: CatalogDetailRequest) -> CoreResult<CatalogDetailPage>`
- [search_page](../src/core.rs#L1739) — `async fn search_page( &self, provider: CatalogProvider, query: CatalogQuery) -> CoreResult<CatalogPage>`
- [cancel](../src/core.rs#L1746) — `async fn cancel(&self, generation: u64)`
- [close](../src/core.rs#L1750) — `async fn close(&self)`

## SourceSearchSession

- [preview_candidate](../src/core.rs#L1683) — `async fn preview_candidate(&self, candidate_id: String) -> CoreResult<PlaybackSnapshot>`
- [search](../src/core.rs#L1696) — `async fn search( &self, provider: String, entry: CatalogEntry, link: Option<String>, generation: u64) -> CoreResult<SourceSearchPage>`
- [attach_candidate](../src/core.rs#L1707) — `async fn attach_candidate( &self, candidate_id: String, track_id: Option<i64>, confirmed: bool) -> CoreResult<TrackSource>`
- [close](../src/core.rs#L1717) — `async fn close(&self)`

## DownloadSearchSession

- [enqueue_download](../src/core.rs#L2214) — `async fn enqueue_download( &self, offer_id: String, filenames: Vec<String>, confirmed: bool) -> CoreResult<DownloadTransferJob>`
- [search](../src/core.rs#L2233) — `async fn search( &self, request: DownloadSearchRequest, generation: u64) -> CoreResult<DownloadSearchPage>`
- [poll](../src/core.rs#L2240) — `async fn poll(&self, generation: u64) -> CoreResult<DownloadSearchPage>`
- [cancel](../src/core.rs#L2243) — `async fn cancel(&self) -> DownloadSearchPage`
- [close](../src/core.rs#L2246) — `async fn close(&self)`

## Contratos auxiliares

- `open(config: CoreConfig) -> CoreResult<Arc<DurvaldCore>>`: função livre de fábrica, compilada com a feature `uniffi`, em `core.rs`.
- `CoreConfig::new(app_support_dir: String, keychain_service: String) -> CoreConfig`: construtor de defaults de caminhos, em `api.rs`.
- `EmbeddedPlaybackHost::execute(command: EmbeddedPlaybackCommand) -> bool`: callback implementado pelo cliente; entrega de comando e confirmação de Stop conforme contrato de `api/embedded.rs`.

## Índice de estruturas, enums, alias e trait de API

Há **157 declarações públicas** nos arquivos `api.rs` e `api/*.rs` neste snapshot.
Esta contagem inclui `CoreResult` e o callback, e não inclui tipos internos do domínio
ou os quatro handles definidos em `core.rs`. O link abre a definição com seus campos
ou variantes; a tabela de estruturas principais do guia explica o significado.

### src/api.rs

| Tipo | Forma | Definição |
| --- | --- | --- |
| `LocalAlbumRecommendation` | `struct` | [Código](../src/api.rs#L23) |
| `LocalRecommendations` | `struct` | [Código](../src/api.rs#L30) |
| `RecommendationEvent` | `enum` | [Código](../src/api.rs#L37) |
| `RecommendationMetrics` | `struct` | [Código](../src/api.rs#L44) |
| `AlbumCollectionDefinition` | `struct` | [Código](../src/api.rs#L52) |
| `AlbumCollection` | `struct` | [Código](../src/api.rs#L61) |
| `AlbumCollectionItem` | `struct` | [Código](../src/api.rs#L72) |
| `AlbumCollectionPage` | `struct` | [Código](../src/api.rs#L82) |
| `CoreConfig` | `struct` | [Código](../src/api.rs#L90) |
| `CoreError` | `enum` | [Código](../src/api.rs#L118) |
| `CoreResult` | `type` | [Código](../src/api.rs#L134) |
| `Track` | `struct` | [Código](../src/api.rs#L139) |
| `RatingGranularity` | `enum` | [Código](../src/api.rs#L166) |
| `RatingRounding` | `enum` | [Código](../src/api.rs#L173) |
| `RatingScalePreferences` | `struct` | [Código](../src/api.rs#L180) |
| `RatingConversionPreview` | `struct` | [Código](../src/api.rs#L186) |
| `RatingPreferenceChange` | `struct` | [Código](../src/api.rs#L195) |
| `TrackMetadataEdit` | `struct` | [Código](../src/api.rs#L203) |
| `TrackInfo` | `struct` | [Código](../src/api.rs#L219) |
| `LibraryRepairTrack` | `struct` | [Código](../src/api.rs#L227) |
| `LibraryRepairSuggestion` | `struct` | [Código](../src/api.rs#L241) |
| `DuplicateTrackGroup` | `struct` | [Código](../src/api.rs#L250) |
| `LibraryRepairAnalysis` | `struct` | [Código](../src/api.rs#L257) |
| `PlaybackHistoryItem` | `struct` | [Código](../src/api.rs#L266) |
| `TrackPage` | `struct` | [Código](../src/api.rs#L280) |
| `PlaybackHistoryPage` | `struct` | [Código](../src/api.rs#L288) |
| `Release` | `struct` | [Código](../src/api.rs#L296) |
| `HomeLibrary` | `struct` | [Código](../src/api.rs#L319) |
| `ReleasePage` | `struct` | [Código](../src/api.rs#L327) |
| `Artist` | `struct` | [Código](../src/api.rs#L335) |
| `Playlist` | `struct` | [Código](../src/api.rs#L343) |
| `SmartPlaylistRule` | `struct` | [Código](../src/api.rs#L359) |
| `SmartPlaylistDefinition` | `struct` | [Código](../src/api.rs#L367) |
| `ReplayPeriod` | `enum` | [Código](../src/api.rs#L378) |
| `ReplayRequest` | `struct` | [Código](../src/api.rs#L387) |
| `ReplaySaveMode` | `enum` | [Código](../src/api.rs#L395) |
| `ReplayPreview` | `struct` | [Código](../src/api.rs#L403) |
| `PlaylistTrack` | `struct` | [Código](../src/api.rs#L418) |
| `QueueItem` | `struct` | [Código](../src/api.rs#L428) |
| `PlaybackSnapshot` | `struct` | [Código](../src/api.rs#L438) |
| `RepeatMode` | `enum` | [Código](../src/api.rs#L457) |
| `LastFmStatus` | `struct` | [Código](../src/api.rs#L466) |
| `ScanProgress` | `struct` | [Código](../src/api.rs#L474) |
| `ScanPhase` | `enum` | [Código](../src/api.rs#L486) |
| `ScanResult` | `struct` | [Código](../src/api.rs#L496) |
| `LastSession` | `struct` | [Código](../src/api.rs#L508) |
| `Settings` | `struct` | [Código](../src/api.rs#L524) |
| `EqualizerSettings` | `struct` | [Código](../src/api.rs#L544) |
| `EqualizerMetrics` | `struct` | [Código](../src/api.rs#L564) |
| `SpectrumSnapshot` | `struct` | [Código](../src/api.rs#L573) |
| `AudioOutputDevice` | `struct` | [Código](../src/api.rs#L579) |
| `AudioOutputState` | `struct` | [Código](../src/api.rs#L587) |
| `KeyValuePair` | `struct` | [Código](../src/api.rs#L597) |
| `AudioMetadata` | `struct` | [Código](../src/api.rs#L605) |
| `SearchResults` | `struct` | [Código](../src/api.rs#L626) |
| `AuthTokenResponse` | `struct` | [Código](../src/api.rs#L636) |
| `SessionResponse` | `struct` | [Código](../src/api.rs#L644) |
| `UserTag` | `struct` | [Código](../src/api.rs#L651) |
| `UserTagLink` | `struct` | [Código](../src/api.rs#L657) |
| `UserTagLibrary` | `struct` | [Código](../src/api.rs#L663) |
| `ListenListEntry` | `struct` | [Código](../src/api.rs#L672) |
| `ClassificationKind` | `enum` | [Código](../src/api.rs#L687) |
| `ClassificationTarget` | `enum` | [Código](../src/api.rs#L693) |
| `ClassificationTerm` | `struct` | [Código](../src/api.rs#L700) |
| `ClassificationLink` | `struct` | [Código](../src/api.rs#L712) |
| `ClassificationPage` | `struct` | [Código](../src/api.rs#L718) |

### src/api/catalog.rs

| Tipo | Forma | Definição |
| --- | --- | --- |
| `CatalogProvider` | `enum` | [Código](../src/api/catalog.rs#L6) |
| `CatalogScope` | `enum` | [Código](../src/api/catalog.rs#L12) |
| `CatalogFilter` | `enum` | [Código](../src/api/catalog.rs#L18) |
| `CatalogItemKind` | `enum` | [Código](../src/api/catalog.rs#L26) |
| `CatalogFailure` | `enum` | [Código](../src/api/catalog.rs#L41) |
| `CatalogQuery` | `struct` | [Código](../src/api/catalog.rs#L52) |
| `CatalogItem` | `struct` | [Código](../src/api/catalog.rs#L64) |
| `CatalogPage` | `struct` | [Código](../src/api/catalog.rs#L77) |
| `CatalogReference` | `struct` | [Código](../src/api/catalog.rs#L90) |
| `CatalogEntry` | `struct` | [Código](../src/api/catalog.rs#L97) |
| `CatalogSelection` | `struct` | [Código](../src/api/catalog.rs#L107) |
| `CatalogDetailSection` | `enum` | [Código](../src/api/catalog.rs#L114) |
| `CatalogDetailRequest` | `struct` | [Código](../src/api/catalog.rs#L125) |
| `CatalogDetailPage` | `struct` | [Código](../src/api/catalog.rs#L134) |

### src/api/download_search.rs

| Tipo | Forma | Definição |
| --- | --- | --- |
| `DownloadSearchSettings` | `struct` | [Código](../src/api/download_search.rs#L5) |
| `DownloadExpectedTrack` | `struct` | [Código](../src/api/download_search.rs#L13) |
| `DownloadSearchRequest` | `struct` | [Código](../src/api/download_search.rs#L21) |
| `DownloadOfferFile` | `struct` | [Código](../src/api/download_search.rs#L27) |
| `DownloadOfferGroup` | `struct` | [Código](../src/api/download_search.rs#L38) |
| `DownloadSearchState` | `enum` | [Código](../src/api/download_search.rs#L54) |
| `DownloadSearchFailure` | `enum` | [Código](../src/api/download_search.rs#L63) |
| `DownloadSearchPage` | `struct` | [Código](../src/api/download_search.rs#L75) |

### src/api/download_transfers.rs

| Tipo | Forma | Definição |
| --- | --- | --- |
| `DownloadTransferSettings` | `struct` | [Código](../src/api/download_transfers.rs#L5) |
| `DownloadFileState` | `enum` | [Código](../src/api/download_transfers.rs#L14) |
| `DownloadTransferFile` | `struct` | [Código](../src/api/download_transfers.rs#L27) |
| `DownloadTransferJob` | `struct` | [Código](../src/api/download_transfers.rs#L40) |
| `DownloadImportPreview` | `struct` | [Código](../src/api/download_transfers.rs#L55) |

### src/api/embedded.rs

| Tipo | Forma | Definição |
| --- | --- | --- |
| `EmbeddedPlaybackState` | `enum` | [Código](../src/api/embedded.rs#L5) |
| `EmbeddedCommandKind` | `enum` | [Código](../src/api/embedded.rs#L14) |
| `EmbeddedPlaybackCommand` | `struct` | [Código](../src/api/embedded.rs#L24) |
| `EmbeddedPlaybackHost` | `trait` | [Código](../src/api/embedded.rs#L33) |
| `EmbeddedEventKind` | `enum` | [Código](../src/api/embedded.rs#L38) |
| `EmbeddedPlaybackEvent` | `struct` | [Código](../src/api/embedded.rs#L49) |
| `EmbeddedPlaybackSnapshot` | `struct` | [Código](../src/api/embedded.rs#L58) |
| `PlaybackSourceStatus` | `struct` | [Código](../src/api/embedded.rs#L73) |

### src/api/enrichment.rs

| Tipo | Forma | Definição |
| --- | --- | --- |
| `FollowedArtist` | `struct` | [Código](../src/api/enrichment.rs#L8) |
| `ArtistNewsKind` | `enum` | [Código](../src/api/enrichment.rs#L22) |
| `ArtistNewsItem` | `struct` | [Código](../src/api/enrichment.rs#L30) |
| `ArtistNewsQuery` | `struct` | [Código](../src/api/enrichment.rs#L42) |
| `ArtistNewsPage` | `struct` | [Código](../src/api/enrichment.rs#L54) |
| `EnrichmentProvider` | `enum` | [Código](../src/api/enrichment.rs#L64) |
| `EnrichmentSettings` | `struct` | [Código](../src/api/enrichment.rs#L78) |
| `ArtistIdentityStatus` | `enum` | [Código](../src/api/enrichment.rs#L97) |
| `ArtistEntityKind` | `enum` | [Código](../src/api/enrichment.rs#L107) |
| `ArtistPartialDate` | `struct` | [Código](../src/api/enrichment.rs#L117) |
| `EnrichmentAttribution` | `struct` | [Código](../src/api/enrichment.rs#L125) |
| `ArtistProfile` | `struct` | [Código](../src/api/enrichment.rs#L137) |
| `ArtistProfileSource` | `struct` | [Código](../src/api/enrichment.rs#L150) |
| `ArtistImageReference` | `struct` | [Código](../src/api/enrichment.rs#L162) |
| `ExternalArtworkScope` | `enum` | [Código](../src/api/enrichment.rs#L182) |
| `ExternalReleaseArtwork` | `struct` | [Código](../src/api/enrichment.rs#L189) |
| `ExternalReleaseGroup` | `struct` | [Código](../src/api/enrichment.rs#L198) |
| `ExternalReleaseTrack` | `struct` | [Código](../src/api/enrichment.rs#L216) |
| `ExternalReleaseDetails` | `struct` | [Código](../src/api/enrichment.rs#L228) |
| `ArtistDiscographyPage` | `struct` | [Código](../src/api/enrichment.rs#L249) |
| `ArtistPopularTrack` | `struct` | [Código](../src/api/enrichment.rs#L267) |
| `ArtistPopularTracks` | `struct` | [Código](../src/api/enrichment.rs#L280) |
| `ArtistProfileField` | `enum` | [Código](../src/api/enrichment.rs#L292) |
| `ArtistFieldOverride` | `struct` | [Código](../src/api/enrichment.rs#L306) |
| `SimilarArtist` | `struct` | [Código](../src/api/enrichment.rs#L314) |
| `RemoteArtistSelection` | `struct` | [Código](../src/api/enrichment.rs#L331) |
| `ArtistDetails` | `struct` | [Código](../src/api/enrichment.rs#L340) |
| `ArtistIdentityOrigin` | `enum` | [Código](../src/api/enrichment.rs#L357) |
| `ArtistIdentity` | `struct` | [Código](../src/api/enrichment.rs#L364) |
| `ArtistIdentityCandidate` | `struct` | [Código](../src/api/enrichment.rs#L377) |
| `ArtistIdentityLookupStatus` | `enum` | [Código](../src/api/enrichment.rs#L388) |
| `ArtistIdentityCandidates` | `struct` | [Código](../src/api/enrichment.rs#L399) |
| `ArtistRefreshSection` | `enum` | [Código](../src/api/enrichment.rs#L412) |
| `ArtistRefreshRequest` | `struct` | [Código](../src/api/enrichment.rs#L423) |
| `ArtistRefreshStatus` | `enum` | [Código](../src/api/enrichment.rs#L434) |
| `ArtistRefreshDiagnosticCode` | `enum` | [Código](../src/api/enrichment.rs#L454) |
| `CoverRefreshProgress` | `struct` | [Código](../src/api/enrichment.rs#L467) |
| `ArtistRefreshSectionResult` | `struct` | [Código](../src/api/enrichment.rs#L476) |
| `ArtistRefreshResult` | `struct` | [Código](../src/api/enrichment.rs#L487) |

### src/api/integration_diagnostics.rs

| Tipo | Forma | Definição |
| --- | --- | --- |
| `IntegrationOperation` | `enum` | [Código](../src/api/integration_diagnostics.rs#L5) |
| `IntegrationOutcome` | `enum` | [Código](../src/api/integration_diagnostics.rs#L17) |
| `IntegrationMeasurement` | `struct` | [Código](../src/api/integration_diagnostics.rs#L29) |
| `IntegrationDiagnostic` | `struct` | [Código](../src/api/integration_diagnostics.rs#L43) |
| `IntegrationDiagnostics` | `struct` | [Código](../src/api/integration_diagnostics.rs#L51) |

### src/api/service_collections.rs

| Tipo | Forma | Definição |
| --- | --- | --- |
| `ServiceProvider` | `enum` | [Código](../src/api/service_collections.rs#L5) |
| `ServiceImportSettings` | `struct` | [Código](../src/api/service_collections.rs#L12) |
| `ServiceMediaAccess` | `enum` | [Código](../src/api/service_collections.rs#L19) |
| `ServiceImportFailure` | `enum` | [Código](../src/api/service_collections.rs#L29) |
| `ServiceCollectionItem` | `struct` | [Código](../src/api/service_collections.rs#L44) |
| `ServiceCollectionJob` | `struct` | [Código](../src/api/service_collections.rs#L54) |

### src/api/sources.rs

| Tipo | Forma | Definição |
| --- | --- | --- |
| `SourceCapability` | `enum` | [Código](../src/api/sources.rs#L5) |
| `SourceCandidate` | `struct` | [Código](../src/api/sources.rs#L15) |
| `SourceSearchPage` | `struct` | [Código](../src/api/sources.rs#L28) |
| `SourceProvider` | `struct` | [Código](../src/api/sources.rs#L36) |
| `TrackSource` | `struct` | [Código](../src/api/sources.rs#L43) |
| `SourceTestResult` | `struct` | [Código](../src/api/sources.rs#L63) |

## Como conferir se esta referência ficou desatualizada

Os links e assinaturas referem-se ao snapshot; linhas podem mudar. Conferir os
nomes e assinaturas de `impl DurvaldCore`, `impl CatalogSearchSession`,
`impl SourceSearchSession` e `impl DownloadSearchSession`, além dos reexports de
`lib.rs`. Métodos `pub(crate)` e helpers de teste não são API de cliente.

Hashes SHA-256 dos arquivos de entrada no momento da extração:

| Arquivo | SHA-256 |
| --- | --- |
| `src/core.rs` | `b6669cb677277f70d08687eb72aa78a7a3cbd4e0af2ea52bf36fb03851c03cc5` |
| `src/api.rs` | `5e8679378149423c3180cc3e6bf81bf6f8417822bbebc8fa90fc46abf01aa96d` |
| `src/api/catalog.rs` | `ac1f2be46ad666dba25a3954616b866f4950b9fa4769d5d03358aff6591e0a61` |
| `src/api/download_search.rs` | `9593118652a095d5bbbce4ea02be153108434710de1cf413ecf6a5fc139ff082` |
| `src/api/download_transfers.rs` | `7594fd80bb7ce1d02a76f82eef70fabbf01b87a2cedc786cb9fe5757f05277c6` |
| `src/api/embedded.rs` | `f3b544f26b81cf7798dc949dd2d586a458224e9796605d34dab032e8950ac550` |
| `src/api/enrichment.rs` | `4f9bb88b9f3e1ec73c5043b9f59c58dbe9a027d45d364a04ed4a1413a7b74fe3` |
| `src/api/integration_diagnostics.rs` | `f20eb68a0c363c3a845b4b07bbe6258e55172c8169b4f727d8793996ebd95d48` |
| `src/api/service_collections.rs` | `76f82727063476321a15697c77a844bd85d92779841a445a561ded3492ccc8c0` |
| `src/api/sources.rs` | `7be97137ca9369e6c5ca156d8d861b822257fe58c7b97bd98cb5d04b1e798ae1` |
