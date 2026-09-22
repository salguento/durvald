use durvald_core::{
    CoreConfig, CoreError, CoreResult, DurvaldCore, PlaybackSnapshot, Release, ScanResult,
    Settings, Track,
};

fn assert_public_type<T>() {}

#[test]
fn protected_root_reexports_compile() {
    assert_public_type::<CoreConfig>();
    assert_public_type::<CoreError>();
    assert_public_type::<CoreResult<()>>();
    assert_public_type::<DurvaldCore>();
    assert_public_type::<PlaybackSnapshot>();
    assert_public_type::<Release>();
    assert_public_type::<ScanResult>();
    assert_public_type::<Settings>();
    assert_public_type::<Track>();
}

fn error_kind(error: CoreError) -> &'static str {
    match error {
        CoreError::InvalidInput { .. } => "invalid_input",
        CoreError::NotFound { .. } => "not_found",
        CoreError::Storage { .. } => "storage",
        CoreError::Playback { .. } => "playback",
        CoreError::Authentication { .. } => "authentication",
        CoreError::Network { .. } => "network",
    }
}

#[test]
fn core_error_exposes_stable_public_variants() {
    let cases = [
        (
            CoreError::InvalidInput {
                message: "example".into(),
            },
            "invalid_input",
        ),
        (
            CoreError::NotFound {
                message: "example".into(),
            },
            "not_found",
        ),
        (
            CoreError::Storage {
                message: "example".into(),
            },
            "storage",
        ),
        (
            CoreError::Playback {
                message: "example".into(),
            },
            "playback",
        ),
        (
            CoreError::Authentication {
                message: "example".into(),
            },
            "authentication",
        ),
        (
            CoreError::Network {
                message: "example".into(),
            },
            "network",
        ),
    ];

    for (error, expected) in cases {
        assert_eq!(error_kind(error), expected);
    }
}
