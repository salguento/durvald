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
