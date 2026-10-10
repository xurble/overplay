# Overplay

Overplay is an Apple Music player for iPhone, iPad and CarPlay that keeps a
main playlist fresh. Its priorities, in order, decide every trade-off (see
**Product priorities** in [the spec](OVERPLAY_DESIGN_SPEC.md)):

1. **A stable, fast, reliable music player.**
2. **CarPlay and Siri first:** playlist management with the phone in a pocket.
   Siri support is planned, not yet built.
3. **Reliable playlist management:** a One True Playlist, a single Triage
   bucket and Retired, with each logical track in exactly one of them.
4. **Statistics:** play and skip counts that inform curation, kept additive and
   best-effort.

A native Mac target is planned.

## How It Works

The **One True Playlist** is the main playlist Overplay manages. Everything
awaiting review lives in one **Triage** bucket, fed by any number of
contributing Apple Music playlists such as Shazam saves, TikTok discoveries or
a friend's playlist. You triage in one place rather than playlist by playlist.
Promotion moves a track from Triage into the One True Playlist, keeping its
history.

Retiring is always an explicit user action. Overplay records it locally and,
where Apple Music allows, also removes the track from the linked playlist; if
that fails, the local retirement still keeps the track out of Active playback.
A retired track can be moved back to Triage or into the One True Playlist.

Playlists are shown and queued newest-added first (Retired: newest-retired
first). MusicKit owns shuffle and repeat once the queue is loaded.

## Playback

When Overplay starts a playlist it saves a device-local playback intent: the
playlist, the scope and the ordered tracks it handed to MusicKit's application
music player. Nothing the player reports can erase that record. The app, the
mini player and CarPlay all show the track the player actually reports.
Overplay matches that track to the intent by identifier, or by unique title and
artist, to attach its counts and curation actions. A track it cannot match is
still shown; it is simply not counted.

System Now Playing belongs to Apple's player host. Lock Screen, Control
Center, headset and CarPlay transport controls act on the player directly.
Overplay observes every change through one path, whichever surface caused it.
Every command is a single MusicKit call. A failed play or a stalled stream
shows the same message on every surface. Pressing Play runs a short recovery
sequence; nothing retries automatically. Playback can resume before the
library has finished restoring from iCloud.

## Statistics

Skips and playthroughs are judged from witnessed listening time: a skip counts
only if Overplay saw enough of the session, and anything ambiguous counts
nothing. If iOS suspends Overplay while the player continues, skips are never
reconstructed; playthroughs are recovered only when persisted observations or
Apple Music library evidence prove them. Each counted play or skip is an
immutable ledger event for the track, and displayed counts are derived from
those events, so merges and resets add to the history rather than overwrite it.

Track rows and Now Playing also show Apple Music's own count as
`Overplay/Apple plays` (for example, `1/1 plays`). An unknown Apple count shows
`—`, never zero. The bulk Apple refresh runs at most every 15 minutes, never
while playing or during a playback failure; a track that starts with an unknown
count gets one focused lookup. The full rules, and the known cross-device
caveats, are in the spec under **Play/Skip History** and **Known Defects**.

## Sync and Data

Only songs are imported, copied into new managed playlists, and synced. Music
videos are excluded. Legacy video records and their local membership/history
are removed at startup and during sync; original Apple Music items are untouched.

Shared app data is backed by iCloud/CloudKit so devices on the same account
can share playlist definitions, track stats, promotions, and retirement
history. Linked playlists are periodically re-synced from Apple Music, with
additions and updated track metadata reconciled into the local store. Tracks
that disappear from the remote playlist are left in place locally with their
history preserved; local retirement remains the only way to exclude a track
from Active playback.

Playback state stays local to each device. The currently playing track,
queue, position, selected view, shuffle/repeat state, and window-specific
navigation state do not sync across devices. This lets current iPhone and iPad
devices share Overplay data without controlling each other's playback, and the
planned Mac target must preserve the same separation.

Playlist imports resolve native MusicKit song IDs before matching shared tracks.
An unresolved ID stops that import instead of creating another copy. Library songs
without a catalog match remain valid. The live investigation, regression evidence,
and remaining playlist-ID/artwork work are recorded in
[the identity probe report](Diagnostics/MusicIdentityProbe/README.md).

## Project Shape

- Swift 6, SwiftUI
- iOS 26 and iPadOS 26 or later (native macOS target planned)
- MusicKit-first Apple Music integration
- SwiftData with CloudKit-backed shared state
- CarPlay music player scene
- Adaptive shell: compact navigation on iPhone, split view/sidebar on iPad
- Liquid Glass UI direction
- Swift Testing unit test target (`OverplayTests`) covering repositories,
  playback policies, sync reconciliation, and presentation logic

## Documentation

- [OVERPLAY_DESIGN_SPEC.md](OVERPLAY_DESIGN_SPEC.md) — full product and
  technical direction.
- [TODO.md](TODO.md) — the single living roadmap for remaining platform,
  product, verification, performance, and release-hardening work.
- [AGENTS.md](AGENTS.md) — rules for AI agents working in this repo,
  including the shared playback-surface requirements.
- [Overplay/CarPlaySupport/README-CarPlay.md](Overplay/CarPlaySupport/README-CarPlay.md)
  — current CarPlay surface structure and verification notes.

## Local Configuration

Shared build settings live in `Config/Shared.xcconfig`. Local developer
identifiers should live in `Config/Local.xcconfig`, which
is ignored by git.

To configure a local checkout:

1. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`.
2. Set `DEVELOPMENT_TEAM`.
3. Set `PRODUCT_BUNDLE_IDENTIFIER`.
4. Set `ICLOUD_CONTAINER_IDENTIFIER`.

Apple Music and CloudKit capabilities must be configured in the Apple
Developer portal and in the Xcode target for the identifiers you use.

### Isolated developer app

Select the shared **Overplay Dev** scheme and Run to install **Overplay Dev**
alongside your everyday Overplay app. It uses the **Development** configuration,
which appends `.dev` to your configured bundle identifier. Configure signing
and Apple Music/CarPlay capabilities for that separate identifier as needed.
Do not override it with your everyday app identifier.

This build keeps its SwiftData database, preferences, onboarding state, playback
restoration, and diagnostic files in its own app sandbox. Its database is
persistent and local-only: CloudKit is disabled, and its entitlements contain
no iCloud access. Everyday Overplay data and Overplay play/skip counts are
preserved. All playback surfaces continue to use the shared app runtime.

To start fresh, stop the developer app, **delete Overplay Dev** from the device
(not Offload App), and run the scheme again. Delete only the developer app.
This resets its local data and onboarding state without removing everyday
Overplay. System-managed Apple Music permission prompts may not repeat.

Apple Music remains your real account: playback and playlist edits can still
affect your Apple Music library and its statistics. This is isolation of
Overplay's own data, not a mock MusicKit environment.

The ordinary **Overplay** scheme keeps its existing Debug and Release behavior.
Both schemes use **Release** for Archive/Profile, producing the everyday app.
The developer store requires both `DEBUG` and `OVERPLAY_DEVELOPMENT`; compiling
the developer flag without `DEBUG` fails. A developer build also refuses to
open its store without a `.dev` app identifier, and ordinary builds reject
that reserved suffix instead of connecting the developer app to CloudKit.

## Player sheet startup regression check

Run from Xcode using **My Mac (Mac Catalyst)** with Apple Music authorized.
Confirm startup reaches the dashboard with the collapsed player visible, then
expand and collapse the player. Both layouts must render without a missing
`PlaybackController` environment error. `AppRouter` supplies the existing shared
dependencies directly at the sheet's hosting boundary; do not create a second
controller for the sheet. Repeat on iPhone/iPad after changing this boundary.

This checks a runtime presentation path that controller unit tests do not host.
Verify library access and actual playback separately: a visible player and a
successful subscription check do not prove that MusicKit can prepare its queue.

## Diagnosing Problems

Overplay keeps a local log of its Apple Music calls and timed work: four hours
of per-minute tallies plus the latest 250 notable events, persisted across
relaunch. The same events go to the unified log under category
`MusicKitActivity`, and timed work emits signposts under category
`Performance`.

1. Open **Settings → Apple Music Call Activity**. Copy the **Full Activity
   Report** before clearing it if it holds useful history, then clear it for a
   clean reproduction.
2. Note the device, build, playlist size, connection, foreground or background
   state, whether artwork was already cached, and the real-world time of the
   symptom. Reproduce one scenario at a time.
3. Tap **Refresh**, expand **Full Activity Report**, and copy the text. Do not
   mix a long sync session with a single tap when reading totals. Nested
   timings overlap, so never add operation totals together.
4. For playback, start with the playback selection paths (`resumeCurrent`,
   `inIntentJump`, `newIntent`, `resubmitFromMember`, `sessionCarriedOver`,
   `skipOnReach`), then **Delivery stall detected**, **Recovery attempt (user
   Play)** and **Unattributed player entry**. The report's **Playback
   attribution** section keeps the latest unattributed entries, session
   carry-overs and skips on reach even when sync reads crowd them out of the
   recent calls.
5. For stutter, attach Instruments to a physical-device Development build and
   record Time Profiler, SwiftUI and Points of Interest, filtered to the
   `Performance` category; use Allocations for image memory. The activity
   report alone cannot prove a frame hitch.
6. Keep warm-cache and cold-cache runs separate. Clearing recorded activity
   does not clear cached artwork.
7. Check CarPlay on a physical head unit. Simulator tests cover row
   configuration, not real head-unit layout or live MusicKit playback.

## Current Status

The core product loop is in place: linked playlist management, periodic sync
with reconciliation, complete playlist queue hand-off with MusicKit-owned
shuffle and repeat, skip and playthrough tracking, manual retirement and
promotion, unified history, search and manual add, CarPlay, and the adaptive
iPhone/iPad shell. The initial cross-surface device acceptance pass is complete,
but it remains a standing regression gate as playback code changes. Remaining
work is kept in impact order in `TODO.md`. The app is pre-release: the schema may
still reset between builds under the pre-release data policy in `AGENTS.md`.
