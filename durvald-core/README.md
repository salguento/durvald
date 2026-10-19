# Durvald Core

`durvald-core` is the UI-independent Rust engine for Durvald. It owns library
indexing, SQLite persistence, local playback, playback history, settings, and
Last.fm integration. Native Rust clients such as GTK consume the public Rust API
directly; SwiftUI and other FFI clients use its UniFFI surface. No UI policy
belongs in this crate. See [the Linux frontend](../durvald-gtk/README.md).

## Core contracts

### Paths and managed files

- `CoreConfig::app_support_dir` is created during `open` and owns the SQLite
  database and other application data.
- `CoreConfig::covers_dir` is created during `open` and is the only managed
  artwork location. Scan-time artwork is written as content-addressed files in
  this directory; artwork returned by the API is an absolute managed path.
- Artwork lookup rejects paths outside `covers_dir`, including paths reached
  through a symlink. Clients must treat an `InvalidInput` result as an invalid
  asset reference, not as a path to open themselves.
- Library paths are supplied by the caller. Scanning never follows file or
  directory symlinks, so a library cannot escape its selected roots or loop.

### Scanning and cancellation

- Only one library scan may run at a time. Starting a second scan returns
  `InvalidInput`; cancelling when none is active returns `NotFound`.
- `cancel_library_scan` is cooperative. Directory walking and task scheduling
  stop promptly; metadata awaiting stops within the coordinator polling
  interval and no extracted results are persisted after cancellation.
- Metadata decoders are synchronous third-party work and cannot be safely
  interrupted in the middle of a decode. They check cancellation before and
  after decoding and before cover writes, so any completed work is discarded
  at the next safe boundary.
- A complete scan reconciles deleted files below each scanned root. A partial
  or cancelled scan never removes existing library records.

### Supported local media

The MVP accepts and plays MP3, WAV, FLAC, and Ogg Vorbis (`.ogg`, `.oga`).
This list is defined once in `audio::SUPPORTED_AUDIO_EXTENSIONS` and matches
the enabled Kira/Symphonia features. AAC/M4A, AIFF, WMA, and Opus are not
indexed because no corresponding playback decoder is compiled in.

When volume normalization is enabled, playback applies a valid bounded
`REPLAYGAIN_TRACK_GAIN` tag to each newly loaded track. Files without a valid
tag retain the user-selected volume.

### Gapless playback

The player prepares and buffers the next queued track while the current track
plays. A single Kira sound switches streams at the audio sample boundary, with
no stop/start fade or overlap for automatic advancement. The background worker
only reconciles queue/history and Last.fm events; UI polling does not drive audio
transitions. Pending streams are cancelled when queue order or repeat/shuffle
policy changes. Only the current and next track are buffered.

Symphonia gapless demuxing is enabled so supported files with encoder delay and
padding metadata (such as LAME-tagged MP3s) can discard those extra samples.
Silence in the recording is preserved. Missing/corrupt files, storage underruns,
or adding a successor too late to buffer it cannot provide a seamless boundary.
Manual track changes retain the configured crossfade.

### Public error mapping

The FFI surface reports only `CoreError` variants:

| Variant | Client meaning |
| --- | --- |
| `InvalidInput` | Correct caller input or state before retrying. |
| `NotFound` | The requested item or active operation does not exist. |
| `Storage` | Database, filesystem, or secure-store operation failed. |
| `Playback` | Audio backend/load operation failed; the caller may show a playback error. |
| `Authentication` | Last.fm credentials or authorization require user action. |
| `Network` | A remote Last.fm request failed or was rate-limited; retry according to client policy. |

Error messages are diagnostic only. Clients should branch on the variant, not
parse text. Credential values are never included in diagnostics.

### Playback history

Each completed listen creates a persistent playback-history record, including repeated completions of the same track under Repeat One. The player's internal queue history is separate: it exists only to implement Previous navigation.

### Playback presentation origin

`play_with_context` and `add_to_queue_with_context` attach an opaque presentation
origin to each queue occurrence. `PlaybackSnapshot::source_context` identifies
the active occurrence's origin, independently of the page currently displayed.
Clients highlight a row only when both its track ID and origin match. A repeated
playlist track needs a distinct origin for each original position.

Queue navigation, shuffle, repeat, gapless transitions and session restoration
preserve these origins. Manual queue additions in the macOS client use `queue`;
album and playlist playback retain their respective origins. Calls to the legacy
context-free APIs use an empty origin and cannot inherit a previous collection's
highlight. Contexts must contain no control characters and at most 2048 UTF-8 bytes.

Occurrence metadata is stored as a versioned envelope in the existing last-session
`source_context` column. Legacy plain contexts restore conservatively: they describe
only the current item. This metadata describes presentation, not a media provider,
file path, or listening-history identity.

### Source collections and queue modes

`play_collection` validates the complete ordered collection and prepares its
selected sound before replacing playback and the upcoming queue together. Track
IDs may repeat: the selected original position identifies the occurrence. With
no explicit shuffle preference, the current setting is retained. With shuffle
enabled, a selected occurrence starts first; a collection-level shuffle command
without a selection also chooses a random first occurrence.

The source snapshot is separate from the visible queue. Normal playback includes
only later occurrences; Repeat All starts a complete new cycle at the first
source occurrence. Shuffle includes every other eligible source occurrence in
random queue order. Disabling shuffle rebuilds the original-order suffix after
the current occurrence; enabling it restores earlier occurrences as well.
Neither toggle restarts the active sound. Repeat One retains its existing meaning.

Manual queue additions survive mode changes. Removing a source occurrence from
the queue excludes it from subsequent rebuilds and cycles; clearing the queue
discards the source snapshot so a later shuffle toggle cannot resurrect it.
Full source identity, occurrence positions and exclusions are persisted in the
versioned session envelope, without a database-schema change. Legacy sessions
continue to restore their saved queue without inventing an unknown full source.
