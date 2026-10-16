# Retrospective playlists

Each selected day, week, month or year with enough eligible tracks has a banner immediately after the track ranking. The banner stays hidden below the minimum and while eligibility is being prepared. Opening it creates only a navigation draft. It does not insert a playlist, appear in the sidebar, or modify the library. Preview playback uses its ordered track list directly.

## Size and eligibility

| Period | Minimum | Default | Maximum |
| --- | ---: | ---: | ---: |
| Daily | 5 | 10 | 25 |
| Weekly | 10 | 25 | 50 |
| Monthly | 20 | 50 | 100 |
| Yearly | 50 | 100 | 200 |

These bounds are generation policy, not user settings. The algorithm targets the period’s standard size and uses all available candidates when fewer exist, provided the minimum is met. The maximum is an internal safety bound. No size control is shown in the preview or the saved-playlist editor. Offering a playlist and saving it require the period's minimum number of distinct eligible tracks. If eligibility changes while an existing preview is open, the preview explains that there are not enough eligible tracks and disables saving. Never duplicate tracks or add tracks from outside the selected interval to fill a quota. Missing metadata, hidden tracks, invalid timestamps, future history and zero listening time do not qualify.

## Ranking version 1

Use only playback-history entries in the half-open selected calendar interval `[start, end)`, up to the evaluation time. Lifetime play counts are irrelevant. For each event:

```
d = track duration in seconds (180 if missing, nonfinite or nonpositive)
c = min(seconds actually heard, d) / d
contribution = c * (0.70 + 0.30 * sqrt(clamp(d / 180, 0.25, 4)))
score(track) = sum(contribution of its events)
```

This combines completion-equivalent plays (70% of each event) with a bounded, duration-adjusted component (30%). A full short track contributes at least 0.85 points, a 3-minute track 1.00, and a full track of 12 minutes or more at most 1.30. A 2-hour recording gets no more duration bonus than a 12-minute track. Listening to 3 minutes of a 2-hour recording contributes 0.0325, not a full play. Overreported listening time is capped at one complete play per event.

Rank by score descending, then latest playback timestamp descending (whole epoch seconds), then track ID ascending. The core accumulates events by history ID ascending. Both the read-only preview and saved membership use this same implementation; Swift contains no ranking algorithm or size policy.

## Saving and lifecycle

After a successful save, the draft opens the saved playlist view without a save action. Draft navigation entries are replaced even if saving finishes after leaving the page. Reopening the same draft, including after restarting the app, reuses the created playlist, and concurrent save requests for that draft share one operation. Failed saves remain retryable.

The header places **Salvar na biblioteca** next to **Reproduzir**, without an options button or a separate saving section. For an open period, the native save dialog offers **Manter atualizada** or **Salvar como está**. Live means the same fixed calendar period, not a rolling interval. New live playlists enable automatic conversion at period end; the saved-playlist editor can change this lifecycle setting. Closed-period drafts always save as snapshots.

- Snapshot creation inserts its ordered membership and playlist in one SQLite transaction. It retains no smart definition.
- A live playlist persists a versioned retrospective rule and evaluates candidates when read.
- With automatic conversion enabled, the final ranking is materialized exactly once at or after the interval's end; the smart definition is removed in the same transaction. Subsequent history changes cannot change its membership or order.
- Conversion is checked by playlist-list, playlist-detail and playlist-track reads, including startup. The macOS playback reconciliation loop also refreshes live playlists after history changes and when their deadline passes. If the app was closed at the deadline, conversion happens on the next read/startup.
- Without automatic conversion, the definition stays live but remains bounded to the original interval. Later-period playback never enters it.
- Saved retrospective live playlists have a dedicated settings sheet; the general smart-rule editor must not rewrite their rule.

The existing FFI contract carries a `SmartPlaylistDefinition` with `sort_by: retrospective_score`, `match_all: true`, `descending: true`, a bounded `limit`, and one `retrospective / equals` rule. Its JSON value has `version`, `period`, integer `start_at` and `end_at` epoch seconds, `mode` (`live` or `snapshot`), and `close_automatically`. The client calculates calendar boundaries in its local calendar/time zone, including DST. Rust validates this configuration rather than interpolating it into SQL.

## Replay artwork

The banner and the preview share one responsive SwiftUI artwork template. A worker samples dominant saturated hue clusters from up to eight distinct covers in the generated track order. These colors are harmonized around the leading cover hue; grayscale/missing covers use a deterministic fallback. A SHA-256 seed of scope and calendar boundaries fixes the curves and glow placement, while day/week/month/year markers distinguish periods. The same period and covers produce stable artwork across navigation.

The square 1024-pixel cover is exported from this template, reused in the preview, and sent as an optional `artwork_base64` argument to `save_replay`. The core validates and saves the PNG in the same transaction as playlist membership/definition. The transient image payload is stripped from the stored smart rule. Live-to-snapshot conversion preserves the cover. After saving, a lightweight frozen artwork recipe also keeps the banner aligned with that cover when the live track selection changes during the session. Opening a banner or generating its artwork never saves a playlist. Decoded covers and generated exports use bounded caches and shared in-flight loads.

The backgrounds now have scope-specific silhouettes: daily color fields, a weekly flowing ribbon, monthly interlaced aurora curtains, and deeper annual luminous orbits. Native banner, preview and saved large covers share a calm 10-second periodic animation (cached native texture crossfades); sine/cosine coordinates match position and velocity at the loop boundary. Motion pauses offscreen/inactive and respects Reduce Motion. Small library thumbnails stay static to avoid animating entire lists.

The exported PNG includes a validated, versioned recipe in its description metadata. Saved large covers can reconstruct the same native animation after app relaunch, including snapshot playlists. Ordinary covers and older PNGs without a recipe use the normal static image path. External PNG viewers display the deterministic still poster. Typography uses an unconstrained text line with safe insets to avoid clipping large week numbers in wide banners.

Artwork typography uses a two-row flow layout: brand/scope at the top and a compact period label at the bottom. Monthly editions show `SET 26`; weekly editions show the week number and abbreviated year. Artist names and date ranges are omitted from the cover artwork; the banner alone displays artists as a separate overlay. Scope-specific hue rotations, analogous accents, stronger saturation and contrasting luminance distinguish editions even with identical source covers. The 10-second loop uses broader color-field and ribbon movement while retaining a smooth periodic seam.

Playback no longer runs a SwiftUI TimelineView or Canvas blur every frame. A coalesced bake generates twelve background textures per palette/aspect bucket, then native CALayer opacity animations crossfade them over 10 seconds. The outgoing texture stays opaque under its incoming neighbour, and the last fades over the first to avoid brightness dips at the seam. Typography stays sharp in a static native layer. The texture cache is limited to 32 MiB/eight entries, resolution is capped at 640 pixels for wide banners and 256 high for covers, and resize aspect buckets avoid regeneration on every pixel. Pausing/reuse are covered by unit tests. PNG remains the portable cover export; native playback avoids GIF decoding and palette quantization. The type sits below Replay and all year labels use `’26` style.

The artwork uses equal horizontal and vertical insets of 8.5% of the short edge. Scope type is 3.4% on covers and 6% on banners, below Replay. Saved covers clip both the SwiftUI wrapper and native animated layer to continuous rounded corners. Playback duration is ten seconds; the same baked frames are reused at the faster speed.

The main day/week/month marker uses semibold weight for small-cover legibility. The scope label receives an optical inset to align its visible edge with the rounded Replay lettering.

Square covers compensate the bottom marker using Core Text glyph bounds and font ascender/descender metrics, so equal container padding also produces equal visible top/bottom margins. A pixel-based render test verifies the visible margins for all four scopes within three pixels at 400px.

Monthly wide banners use 96 phase samples rather than twelve: their curtains move far enough along the long axis that sparse crossfades appeared to blink between distant positions. A 480px raster keeps the denser sequence within the existing 32 MiB cache. Square monthly covers and other scopes retain their twelve-frame sequences. Texture animations share an explicit timeline origin. A regression test compares blended samples with the exact intermediate gradient, requiring less than 0.006 mean channel error and at least an 80% reduction against sparse sampling.

Replay provenance persists in `retrospective_playlist_origins`, unique by scope and exact calendar interval. Creation returns the existing row before reranking or checking eligibility. Snapshot materialization, renaming and cover edits retain this provenance; deleting the playlist clears it and permits explicit recreation. The client asks `replay_preview` for saved identity and only caches core responses for navigation. The core performs a one-time import of legacy live rules and PNG origin recipes, then uses persisted database origins independently of artwork. Existing duplicates are not deleted automatically.

## Core API boundary

`replay_preview(ReplayRequest)` returns availability, the core-owned size policy, ordered tracks, whether the period is in progress and the existing saved playlist. `save_replay` applies live/snapshot policy, minimum/standard/maximum sizing and idempotent creation. `update_replay` controls lifecycle without accepting user-supplied smart rules. Requests carry scope and epoch calendar boundaries selected in the client's time zone; names are localized presentation strings. The client supplies PNG art but never builds generation rules. Saved snapshots remain fixed when a caller later requests live mode.

Tests cover all scope sizes, availability without library mutation, preview/saved ordering, history completion scoring, closed-period policy, legacy PNG migration, restart identity without artwork and client delegation without reading history. The generated UniFFI Swift wrappers and embedded native library must be regenerated together when this API changes.
