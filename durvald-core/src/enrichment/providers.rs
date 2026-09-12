pub mod commons;
pub mod cover_art_archive;
pub mod musicbrainz;
pub mod wikidata;
pub mod wikipedia;

#[cfg(test)]
mod smoke_tests {
    use super::*;
    use crate::enrichment::models::{CacheValidators, ProviderResponse};

    /// Manual public-API smoke test. Example:
    /// `DURVALD_SMOKE_MBID=<artist-mbid> cargo test public_musicbrainz_route -- --ignored`
    #[tokio::test]
    #[ignore = "accesses the public MusicBrainz API"]
    async fn public_musicbrainz_route() {
        let mbid = std::env::var("DURVALD_SMOKE_MBID")
            .expect("set DURVALD_SMOKE_MBID to a resolved artist MBID");
        let qid = musicbrainz::MusicBrainz::new()
            .unwrap()
            .wikidata_id(&mbid)
            .await
            .unwrap()
            .expect("artist has no curated Wikidata relation");
        assert!(qid.starts_with('Q'));
    }

    /// `DURVALD_SMOKE_QID=<wikidata-qid> cargo test public_wikimedia_routes -- --ignored`
    #[tokio::test]
    #[ignore = "accesses the public Wikimedia APIs"]
    async fn public_wikimedia_routes() {
        let qid = std::env::var("DURVALD_SMOKE_QID")
            .expect("set DURVALD_SMOKE_QID to an artist Wikidata QID");
        let ProviderResponse::Modified { value: profile, .. } = wikidata::Wikidata::new()
            .unwrap()
            .profile(&qid, "pt", &CacheValidators::default())
            .await
            .unwrap()
        else {
            panic!("an unconditional Wikidata request returned 304")
        };
        assert_eq!(
            profile.profile.attribution.source_url,
            format!("https://www.wikidata.org/wiki/{qid}")
        );
        if let (Some(language), Some(title)) = (profile.article_language, profile.article_title) {
            let response = wikipedia::Wikipedia::new(&language)
                .unwrap()
                .introduction(&title, &language, &CacheValidators::default())
                .await
                .unwrap();
            assert!(matches!(response, ProviderResponse::Modified { .. }));
        }
        if let Some(filename) = profile.commons_file {
            let commons = commons::Commons::new().unwrap();
            let metadata = commons.metadata(&filename).await.unwrap_or_else(|error| {
                panic!("Commons metadata failed for {filename}: {error:?}")
            });
            assert!(
                !commons
                    .download(&metadata.download_url)
                    .await
                    .unwrap()
                    .is_empty()
            );
        }
    }

    /// `DURVALD_SMOKE_RELEASE_GROUP_MBID=<release-group-mbid>
    ///  DURVALD_SMOKE_RELEASE_MBID=<optional-release-mbid>
    ///  cargo test public_cover_art_archive_route -- --ignored`
    #[tokio::test]
    #[ignore = "accesses the public Cover Art Archive API"]
    async fn public_cover_art_archive_route() {
        let group = std::env::var("DURVALD_SMOKE_RELEASE_GROUP_MBID")
            .expect("set DURVALD_SMOKE_RELEASE_GROUP_MBID");
        let release = std::env::var("DURVALD_SMOKE_RELEASE_MBID").ok();
        let archive = cover_art_archive::CoverArtArchive::new().unwrap();
        let candidate = archive
            .artwork(release.as_deref(), &group)
            .await
            .unwrap()
            .expect("no Cover Art Archive image found");
        let downloaded = archive.download(candidate).await.unwrap();
        assert!(!downloaded.bytes.is_empty());
        assert!(downloaded.width > 0 && downloaded.height > 0);
    }
}
