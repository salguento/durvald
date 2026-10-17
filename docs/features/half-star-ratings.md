# Half-star ratings

The core stores exact ratings as optional integer **half-star units**, named
`rating_half_steps` in SQLite/Rust and `ratingHalfSteps` in Swift DTOs. Values are
0…10: 1 means 0.5 stars, 7 means 3.5 stars and 10 means 5 stars. NULL/None is
unrated and remains distinct from a rated zero. The domain validates these units;
no floating-point rating storage is used.

## Migration

`database::ratings::migrate` runs from normal schema initialization. Its version
is recorded in `rating_schema_migrations`. Existing whole-star columns are copied
once into explicit canonical columns using `legacy_rating * 2`, preserving NULL.
This includes songs, releases, missing tracks and the legacy release archive.
Old columns are retained for recovery but are no longer read or written by the
new runtime. No table rebuild or entity-ID change is needed, preserving foreign
keys, playlist/history links and other metadata.

The migration, constraints, default preference and migration marker are committed
together. Invalid legacy values fail the entire transaction rather than being
clamped. Reopening the database does not double-convert existing half-star data.
Canonical columns accept only integer values from 0 through 10.

## Core API

- `set_track_rating_half_steps` and `set_release_rating_half_steps` take exact
  optional units from 0 through 10.
- Track, Release and LibraryRepairTrack DTOs expose `rating_half_steps` explicitly.
- `rating_preferences` returns `RatingScalePreferences`, defaulting to HalfStars.
- `rating_conversion_preview` counts fractional ratings by entity category.
- `update_rating_preferences(granularity, rounding)` changes the preference and,
  when selecting WholeStars, converts existing fractional ratings atomically.

Switching to WholeStars with fractional ratings requires an explicit Up or Down
choice. Up maps 7 to 8, Down maps 7 to 6, and Down maps 1 to rated zero, not NULL.
Only odd values change. Switching back to HalfStars retains the converted values;
previous fractions are not reconstructed. Selecting HalfStars never rounds data,
even if a caller supplies a rounding argument.

Preference changes and rating writes take the SQLite writer lock before reading
policy, preventing races between incoming half-star edits and bulk conversion.
Core setters reject fractional writes in WholeStars mode; SQLite triggers also
protect restore/relink and direct write paths. Clearing a rating remains allowed.
The preference is stored independently from general settings and display toggles.

## Rule compatibility

Smart-playlist field names and saved rule values remain in **star units**. Thus
an existing `rating >= "4"` still means at least four stars; the core translates
it to eight half steps when constructing SQL. New thresholds such as `"4.5"` are
supported, while quarter-star values are rejected. Empty/unrated queries keep
their previous semantics. Sorting uses the canonical exact stored units.

## macOS interface and settings

All runtime UI reads and writes use exact half steps, including native table
cells, album controls, playlists, track information, context menus, sorting and
minimum-rating filters. SF Symbols display full, leading-half-filled and empty
stars. Click the left/right half of a star to select a half/full rating. Native
cells also accept left/right arrow keys on a focused star; SwiftUI controls have
individual accessible rating targets and an adjustable accessibility action.
Clicking the selected value clears it; menus distinguish unrated from rated zero.

Settings → General exposes a native scale picker. Half stars are the default.
Switching to whole stars previews all affected categories and asks for Up, Down
or Cancel when fractions exist. Merely opening/cancelling the dialog does not
write preferences. Conversion is permanent, as stated in the confirmation.
Whole-star mode changes input targets and menu choices without rounding display
values on the client. Changing back to half stars does not restore old fractions.

The store blocks new rating edits while changing scale and drains queued writes
before invoking the atomic core conversion. Rating revisions invalidate pending
UI acknowledgements and native-cell snapshots. Loaded catalog pages, playback,
playlists and metadata/history caches are refreshed after conversion. A failed
conversion keeps the persisted scale and reports the error.

Existing whole-star minimum-rating preferences migrate once to the separate
`albums.minimumRating.halfSteps` key. Smart-playlist rule values remain in star
units (`4`, `4.5`) and use a picker with localized labels. Existing fractional
filter thresholds remain valid even if the user chooses whole-star rating input.

Bindings and the embedded native library are regenerated together. Legacy core
whole-star setters and `LegacyWholeStarRatingInitializers.swift` constructors
remain explicit adapters for old callers/fixtures; there is no lossy DTO getter.

## Validation

Tests cover exact units, one-time migration/restart, foreign-key preservation,
NULL versus zero, validation, rounding both directions across all categories,
missing explicit rounding, rollback on failed conversions, preference
persistence, concurrent edits/conversion, and existing/new smart-rule thresholds.
Existing playlist, library repair and catalog/preference tests are also run.

## End-to-end regression (stage three)

`durvald-core/tests/ratings.rs` boots the normal composition with a committed
pre-half-star SQL fixture and mock audio. It checks one-time migration after
restart, NULL versus zero, favorites/play counts, unchanged playlist IDs/order,
foreign keys, the old whole-star API wrapper, policy persistence and a half-star
write arriving between the conversion preview and confirmation.

`HalfStarRatingFFITests` uses the actual embedded dylib, generated UniFFI bindings
and temporary SQLite files. It round-trips every optional half-step value through
track/release setters and reopens the core, checks typed validation errors, drives
a native rating button through the store, and verifies smart-playlist membership
before/after both rounding directions. These tests do not substitute a fake core.

The large-catalog regression loads 250 of 301 tracks and releases before changing
scale. It caught a single-page reload that silently truncated the loaded catalog
at the core's 200-item page cap. The store now follows the returned cursor until
the loaded window is restored, and retains the next cursor for further scrolling.

`HalfStarRatingUITests` launches the production app and controls with a real core
in its sandbox's temporary directory. It covers mouse input in the left half of
a star, cancelling conversion, rounding both ways, whole-star input, returning to
half stars without recovering discarded fractions, and process relaunches. A
separate album case exercises the SwiftUI control and persisted release rating.
Stable accessibility identifiers cover both native and SwiftUI rating targets.

The DEBUG-only fixture accepts a UUID and creates its own isolated temporary
library; it never takes a user database path, scans audio, starts playback, or
changes persisted presentation preferences. Rating errors belong to the domain;
the application layer does not depend on the SQLite rating error implementation.

Reproduce core regressions:

```sh
cargo test --manifest-path durvald-core/Cargo.toml --features test-support --lib rating
cargo test --manifest-path durvald-core/Cargo.toml --features test-support \
  --test ratings --test public_api --test library --test settings \
  --test core_lifecycle --test fixture_infrastructure
```

Reproduce macOS regression and UI tests:

```sh
xcodebuild -project durvald-macos/Durvald/Durvald.xcodeproj -scheme Durvald \
  -configuration Debug -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:DurvaldTests -only-testing:DurvaldUITests/HalfStarRatingUITests \
  -skip-testing:DurvaldTests/RetrospectiveChartTooltipTests/testRenderedChartCreatesTooltipRegionsForBothBarsOfEveryDay \
  -skip-testing:DurvaldTests/TrackMetadataLayoutTests/testRenderMetadataWindow test
```

The two skipped window-rendering tests were verified to fail identically at HEAD
before this feature. The separate Rust architectural guard also has existing
violations in `application/playlist.rs`; comparing its forbidden dependencies with
HEAD confirms no new violations from ratings. These unrelated failures are not
silently counted as passing regressions.

Validated on macOS on 2026-10-16: 9 focused core unit tests, 56 core integration
regressions, 371 macOS unit tests, and both UI flows passed. The album UI case
also verified the selected accessibility trait after the last control change.
Generated Swift bindings match the embedded wrapper; `git diff --check` passes.

## Final release review

Legacy ratings are validated as integer whole-star values before conversion.
SQLite's implicit arithmetic coercion must never turn malformed text/BLOB values
or fractional legacy values into an apparently valid zero. A regression test
covers text, BLOB, fractional, negative and out-of-range values, verifies rollback
across all tables, and checks that migration can be retried after correcting the
source data. The original values remain intact on failure.

The Release build is also checked separately from Debug. Test-fixture symbols
are absent from the distribution executable; the generated wrapper and embedded
native library are kept synchronized after the final migration fix.

Final-review checks passed: 10 focused core tests, 2 normal-startup migration
integration tests and 4 Swift–Rust FFI tests. The final Release build succeeded
with the updated embedded library; the packaged dylib has the same build UUID and code/data sections as the source artifact (its signing metadata is updated by Xcode).
