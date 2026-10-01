# Durvald

A local-first music player with a shared Rust engine and native desktop interfaces.

Durvald brings together my interests in music, software architecture, and interface design. The project is evolving from an earlier Tauri implementation toward native clients that reuse the same core.

**Status:** Active development. The macOS client is the most advanced interface. The Linux client is in **early development**: it opens a window, initializes the Rust core, and displays the number of tracks stored in its database.

## Overview

Durvald separates music-library and playback logic from platform-specific interfaces:

- **Rust core:** Library indexing, audio playback, SQLite persistence, playback history, settings, and Last.fm integration.
- **macOS client:** A native SwiftUI interface connected to the core through UniFFI.
- **Linux client:** An initial Rust/GTK4 scaffold that opens a window and connects to the core through its public Rust API. It displays the stored track count and can reload that count; importing music, browsing tracks, and controlling playback are not implemented yet.

This structure allows each interface to follow its platform's conventions while sharing application logic.

## Core capabilities

The shared engine includes:

- Local music-library scanning, metadata extraction, and managed artwork.
- Metadata editing and access to embedded lyrics.
- Regular and rule-based smart playlists, ratings, and favorites.
- SQLite storage for library records, settings, and listening history.
- Playback of MP3, WAV, FLAC, and Ogg Vorbis files.
- Queue management, repeat, and shuffle.
- Gapless transitions between queued tracks, subject to file and buffering conditions.
- ReplayGain-based volume normalization when valid track-gain metadata is available.
- A ten-band equalizer and audio spectrum analysis.
- Last.fm authentication, now-playing updates, and scrobbling.
- Optional artist enrichment through MusicBrainz, Wikimedia services, and Cover Art Archive.

Feature availability depends on the client. These capabilities belong to the shared core and are **not yet available through the Linux interface**.

## macOS interface

The SwiftUI client implements library import and scanning, track/album/artist browsing, search, playback controls, queue management, and listening history. It also includes regular and smart playlists, M3U playlist import/export, metadata editing, embedded lyrics, an equalizer, audio output settings, and Last.fm settings.

Optional artist enrichment adds biographies, discographies, and images. Local library browsing and playback do not require this feature. Remote integrations require network access and, for Last.fm, user configuration and authorization.

## Architecture

```text
macOS / SwiftUI                 Linux / GTK4
       |                       Early development
 UniFFI bindings                      |
       |                        Public Rust API
       |                              |
       +--------- durvald-core -------+
                       |
          Library and playback logic
                       |
             SQLite · Local files
                       |
              Last.fm integration
```

The core owns application behavior and persistence. Clients handle presentation, interaction, and platform-specific concerns.

For detailed contracts covering scanning, cancellation, managed artwork, playback, and error handling, see the [core documentation](durvald-core/README.md).

## Repository structure

```text
durvald/
├── durvald-core/     # Shared Rust engine
├── durvald-macos/    # Native macOS client
├── durvald-gtk/      # Early Linux scaffold: window and core connection
├── docs/            # Development notes and plans
└── .github/         # Repository automation configuration
```

## Getting started

Clone the repository:

```bash
git clone https://github.com/salguento/durvald.git
cd durvald
```

### Core development

The Rust core has its own Cargo manifest:

```bash
cargo build --locked --manifest-path durvald-core/Cargo.toml
cargo test --locked --manifest-path durvald-core/Cargo.toml
```

Native dependencies and runtime requirements vary by operating system. See the component documentation before building.

### Linux — early development

The Linux client opens a GTK window, initializes the core, and shows the number of tracks already stored in its database. Its “Atualizar biblioteca” button reloads that count from the database; it does not scan music folders.

**Music import, library browsing, playback controls, and other music-player features are not implemented in the Linux interface.**

The scaffold requires Rust, GTK4 development libraries, native audio dependencies, and a graphical session.

After installing the dependencies described in the [Linux setup guide](durvald-gtk/README.md), run:

```bash
cargo run --locked --manifest-path durvald-gtk/Cargo.toml
```

This starts the development scaffold, not a usable music player.

### macOS

The SwiftUI client lives in [`durvald-macos/`](durvald-macos/). It uses UniFFI bindings to communicate with the Rust core.

The current Xcode project targets macOS 26.5. The binding-generation script builds the Rust library for Apple Silicon (`aarch64-apple-darwin`); an Intel build is not covered by that script.

With Xcode and Rust installed, add the target and regenerate the library and Swift bindings:

```bash
rustup target add aarch64-apple-darwin
bash durvald-macos/scripts/generate-bindings.sh
open durvald-macos/Durvald/Durvald.xcodeproj
```

Build and run the `Durvald` scheme in Xcode. Regenerate the bindings when the core's FFI API changes.

## Current limitations

- The clients are at different stages of development.
- The Linux client is an early scaffold with a window and a connection to the Rust core; music-player functionality remains to be implemented.
- AAC/M4A, AIFF, WMA, and Opus are outside the core's currently documented supported formats.
- Gapless playback depends on decodable files, available buffering, and timely preparation of the next track.
- The documented setup builds the clients from source.
- Both GitHub Actions workflows currently run only through manual dispatch; pushes and pull requests do not trigger them.

## Development approach

Durvald is an independent project developed with AI assistance across implementation and iteration.

It provides a practical setting for exploring shared application architecture, native interfaces, local persistence, and audio playback.

The previous Tauri implementation is available in the [`durvald-tauri`](https://github.com/salguento/durvald-tauri) repository.
