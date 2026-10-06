# Overplay Product and Design Specification

## Specification Status

This document is the canonical specification for Overplay. The playback,
counting and cross-surface sections were rewritten on 2026-10-04 for the
reliable-playback-core rewrite (`PLAY-010` onwards, `COUNT-*`, `LOAD-*`). Other
sections describe behaviour implemented as of 2026-09-30, unless they are
labelled **Planned**. Future work belongs in `TODO.md`. Implementation details
are requirements only when they create observable behaviour or protect a stated
invariant.

Evidence priority is executable tests, public UI and persisted models, then
implementation. Known defects are recorded separately and are not product
requirements. Approaches that were tried and withdrawn are recorded in
**History: Abandoned Playback Approaches** so they are not tried again.

## Purpose

Overplay is an Apple Music companion app for iPhone, iPad, and CarPlay.
It keeps a user's main music playlist fresh while using other playlists as
intake and triage sources.

### Product priorities

These goals are in priority order. When a design or implementation choice
trades one against another, the higher priority wins.

1. **A stable, fast, reliable music player.** Playback never loses track of
   what Overplay asked MusicKit to play, never shows different things on
   different surfaces, and never fails in a way the user cannot recover from
   with Play. Nothing below may gate, delay or rewrite playback.
2. **CarPlay and Siri first.** Playlist management works with the phone in a
   pocket. Playing a playlist and promoting, retiring or restoring the current
   track are reachable from CarPlay and by voice; an action that needs the
   phone screen is, in practice, unavailable. Siri support is **Planned**:
   deferred, not yet built (`TODO.md`, Siri Playlist Management).
3. **Reliable playlist management.** One True Playlist, Triage and Retired
   stay correct, and deduplication keeps each logical track in exactly one of
   them (`PLAYLIST-007`).
4. **Statistics.** Play, skip and Apple play counts inform curation. They
   are additive and best-effort: a late or missing count is acceptable, but a
   stalled player, disagreeing surfaces or a track in two places is not.

Statistics never drive the design of playback, surfaces or playlist
management. For example, if a CarPlay control can only be built by making
Overplay a second Now Playing client again (H-7), priority 1 wins and the
control moves to a CarPlay list template.

The core playlist is the user's **One True Playlist**. Overplay plays it,
tracks the user's own skip and playthrough behaviour, and exposes manual
retirement. Everything awaiting review lives in a single **triage bucket**,
fed by any number of contributing Apple Music playlists. Those contributors
can represent sources such as TikTok saves, Shazam discoveries, a friend's
playlist, or any other Apple Music playlist the user wants to review before
promoting songs into the One True Playlist. The user triages in one place
rather than playlist by playlist.

Overplay maintains its own history and state. It does not rely on Apple
Music's global play count or skip count.

## Requirement Index

| ID | Requirement | Primary evidence |
| --- | --- | --- |
| `PLAT-001` | The current app supports iPhone and iPad on iOS/iPadOS 26+, with CarPlay supplied by the iPhone app. A native Mac target is planned, not implemented. | `Overplay.xcodeproj/project.pbxproj`, `Overplay/App/Shell/PlatformShell.swift` |
| `AUTH-001` | Normal use requires Apple Music authorization, catalogue playback capability, and Sync Library. The simulator supplies a ready state for development. | `Overplay/Services/MusicAuthorizationService.swift`, `Overplay/App/StartupAuthorizationGate.swift` |
| `PLAYLIST-001` | Exactly one active One True Playlist is selected. Selecting another demotes the previous main playlist to a triage source. | `Overplay/Persistence/PlaylistRepository.swift`, `OverplayTests/NewModelRepositoryTests.swift` |
| `PLAYLIST-003` | There is at most one triage bucket. It owns every triage item, is ensured during startup, and has a reserved `musicPlaylistID` rather than an Apple Music playlist, so it is never fetched or synced directly. | `Overplay/Persistence/PlaylistRepository.swift`, `OverplayTests/TriageBucketTests.swift` |
| `PLAYLIST-004` | Sources contribute attachments, not duplicate rows. A deliberate source link/re-link revives older retirements into Triage; ordinary sync never revives them. Active OTP takes precedence over source intake. | `Overplay/Services/TrackLocationService.swift`, `OverplayTests/GlobalTrackOwnershipTests.swift` |
| `PLAYLIST-005` | Last-source unlink deletes untouched, non-explicit active Triage rows and unowned retired 0/0 rows. Active explicit keep or prior listening (even reset) survives. Nonzero counts and necessary OTP suppression always survive. | `Overplay/Persistence/TrackRetentionPolicy.swift`, `OverplayTests/GlobalTrackOwnershipTests.swift` |
| `PLAYLIST-007` | One item per track app-wide. OTP, Triage and global Retired are three top-level collections; every retired item belongs to the bucket. | `Overplay/Persistence/PlaylistItemRepository.swift`, `Overplay/Services/TrackLocationService.swift` |
| `PLAYLIST-008` | Every retire or duplicate merge out of a managed One True Playlist removes the song from the Apple Music playlist, retried after each sync. A rewrite runs only when the device's copy matches iCloud's; removed or absent songs release suppression and get the retention rule. Promotion does not add a song iCloud already holds. | `Overplay/Services/OneTruePlaylistRemoteMembership.swift`, `OverplayTests/OneTruePlaylistRemoteMembershipTests.swift` |
| `PLAYLIST-009` | From iPhone or iPad, the user can rebuild the One True Playlist's Apple Music playlist: Overplay creates a new playlist of the active songs in Overplay's order and relinks the same One True Playlist to it, keeping counts, retirements and history. Nothing is deleted from Apple Music. | `Overplay/Services/OneTruePlaylistRebuildService.swift`, `OverplayTests/OneTruePlaylistRebuildTests.swift` |
| `PLAYLIST-010` | Ordinary sync skips a song no lookup can identify: the rest syncs; the skipped row is untouched; absence-dependent steps are skipped; the playlist keeps an error and retries. More than a fifth unidentifiable, or any in a copy, still stops the fetch. | `Overplay/Services/AppleMusicPlaylistSourceSync.swift`, `OverplayTests/MusicLibraryIdentityImportTests.swift` |
| `PLAYLIST-011` | The retention rule is re-applied by a sweep at startup and after each background sync cycle, to retired rows and deferred deletions only, with every deletion recorded in history. | `Overplay/Persistence/TrackRetentionPolicy.swift`, `OverplayTests/SyncCleanupTests.swift` |
| `LOC-001` | A retirement or restore survives another device's stale CloudKit write. After each import and at startup, a song's newest `evicted`/`restored` history event re-applies its decision when it is newer than the row's `locationChangedAt`; promotions are left to the next One True Playlist sync. | `Overplay/Services/TrackLocationService.swift`, `OverplayTests/TrackLocationRepairTests.swift` |
| `PLAYLIST-006` | Pre-bucket triage data migrates onto the bucket at startup. The migration is idempotent and keyed on the stored legacy role value, not a local flag. | `Overplay/Persistence/TriageBucketMigrationService.swift`, `OverplayTests/TriageBucketTests.swift` |
| `PLAYLIST-002` | Initial setup can create a managed playlist, copy an existing playlist into a managed playlist, or link an existing playlist as incoming-only. | `Overplay/ViewModels/PlaylistSelectionViewModel.swift`, `Overplay/Services/PlaylistSyncService.swift` |
| `SYNC-001` | Automatic sync starts shortly after authorization, runs every 30 minutes, skips fresh successful playlists, retries failed playlists, prioritizes the playing and selected playlists, and pauses while a playback failure is active. | `Overplay/Services/PeriodicPlaylistSyncService.swift`, `OverplayTests/PeriodicPlaylistSyncServiceTests.swift` |
| `SYNC-002` | Sync is idempotent, collapses duplicate identities, preserves history, and leaves remotely missing tracks locally playable unless retired. Sync never mutates the live playback queue. | `Overplay/Services/PlaylistSyncService.swift`, `OverplayTests/PlaylistSyncReconciliationTests.swift` |
| `MUT-001` | Successful promotion moves the existing item into OTP with its statistics and history; no source copy remains. Retired offers Move to Triage (explicit keep) and Move to One True Playlist. | `Overplay/Services/PlaylistMutationService.swift`, `OverplayTests/PlaylistMutationServiceTests.swift` |
| `MUT-002` | Apple Music search can add songs only to active playlists that allow remote writes. | `Overplay/ViewModels/SearchMusicViewModel.swift`, `OverplayTests/SearchMusicViewModelTests.swift` |
| `RETIRE-001` | Retirement is authoritative locally and globally equivalent from OTP/Triage. Managed OTP retirement attempts remote removal from rows and Now Playing; incoming-only OTP and Triage retirement stay local. Stale OTP membership cannot revive or silently re-promote the row. | `Overplay/Services/PlaybackController.swift`, `Overplay/Services/TrackLocationService.swift` |
| `PLAY-004` | MusicKit owns shuffle and repeat. Overplay writes what a surface asked for, displays what the player reports, and never reorders or rebuilds the queue to emulate them. | `Overplay/Services/PlaybackController.swift` |
| `PLAY-005` | Starting playback hands MusicKit the complete display order for the selected scope in one queue, omitting only tracks that cannot be prepared. | `Overplay/Services/PlaybackController.swift` |
| `PLAY-010` | Starting playback records a device-local playback intent (playlist, scope, ordered members with identifiers and metadata) before the queue is submitted. Only a new submission replaces it and only a database reset clears it; no observation, error or timeout can. | `Overplay/Playback/PlaybackIntent.swift` |
| `PLAY-011` | The player is the authority on what is audible. Every Overplay surface displays the player-reported track, position, status and modes, even when the entry cannot be attributed. | `Overplay/Services/PlaybackController.swift` |
| `PLAY-012` | The current entry is attributed to an intent member by identifier, then by unique normalized title/artist with duration corroboration. An unattributed entry is displayed, not counted, and has curation disabled; attribution never clears context. | `Overplay/Playback/PlaybackAttribution.swift` |
| `PLAY-013` | Every transport command is one direct MusicKit call: no confirmation loop, no rejection of overlapping commands, no automatic queue replacement or retry. Displayed state changes only through observation. | `Overplay/Services/PlaybackController.swift` |
| `PLAY-014` | Failures are shared across surfaces and recovered only by a user Play press through a bounded ladder (play; prepare and play; resubmit the intent at the current member and position, looking that member's track up again). Pause is never disabled. | `Overplay/Services/PlaybackController.swift` |
| `PLAY-015` | Membership changes never mutate the live queue. Retiring the current track issues Next; a member that left the scope is skipped when reached; additions appear at the next start. | `Overplay/Services/PlaybackController.swift` |
| `PLAY-016` | Overplay does not write `MPNowPlayingInfoCenter` or register transport `MPRemoteCommandCenter` handlers; the `ApplicationMusicPlayer` host owns system Now Playing. A default-off diagnostic mirror exists only for device verification. | `Overplay/Services/SystemNowPlayingBridge.swift` |
| `PLAY-017` | Native `Track` objects needed for playback are cached on disk per device; cold launches do not need to re-resolve the whole playlist, a cached track is reused only while it is the song its record names (its library or catalog ID), a library ID that no longer exists in the account library falls back to the record's catalog ID, and unresolvable songs are omitted rather than failing playback, with each omission recorded in the activity log. | `Overplay/Services/DevicePlaybackCache.swift` |
| `COUNT-001` | Counting observes playback and never commands, delays or vetoes it. Skips require witnessed listening; playthroughs are position-based; suspended spans never produce skips. | `Overplay/Playback/ListeningSessionTracker.swift`, `Overplay/UseCases/PlaybackSessionEvaluationService.swift` |
| `COUNT-002` | Counted outcomes are immutable ledger events with idempotent session IDs. Displayed counts are derived from the ledger, including absorbed track identities; merges and resets never edit counts. | `Overplay/Services/ListenLedger.swift`, `Overplay/Models/ListenEvent.swift` |
| `LOAD-001` | Overplay adds no avoidable Apple Music load during playback: no steady-state queue enumeration, bulk Apple play-count refresh at most every 15 minutes and never while playing, library discovery scans at most every 6 hours, and no background MusicKit work while a playback failure is active. | `Overplay/Services/ApplePlayCountSyncService.swift`, `Overplay/Services/PeriodicPlaylistSyncService.swift` |
| `CAR-002` | Presented menus retain row and artwork identity. Only changed visible values are published; section replacement requires structural change. Presentation reads never mutate playback or persistence. | `Overplay/CarPlaySupport/CarPlayListRenderer.swift` |
| `CAR-001` | CarPlay is playlists, then the tracks in one, then Now Playing. Every playback and curation action a driver needs is on Now Playing. | `Overplay/CarPlaySupport/CarPlayCoordinator.swift`, `Overplay/CarPlaySupport/CarPlayNowPlayingActionPolicy.swift` |
| `TRACK-001` | Skips require witnessed listening and are never reconstructed from stale or suspended spans. Playthroughs are position-based and can be recovered only from explicit proof. | `Overplay/UseCases/PlaybackSessionEvaluationService.swift`, `Overplay/Services/PlaybackReconciliationService.swift` |
| `HISTORY-001` | History is filterable and paged. Ignored-skip events expire after 30 days and other events after 365 days, with bounded cleanup. History is never the source of counts. | `Overplay/Views/HistoryView.swift`, `Overplay/Services/HistoryRetentionService.swift` |
| `SETTINGS-001` | Current settings cover tracking thresholds, statistics reset, shared database reset, playlist selection, MusicKit diagnostics, and the diagnostic Now Playing mirror. | `Overplay/Views/SettingsView.swift`, `Overplay/ViewModels/SettingsViewModel.swift` |
| `SURFACE-001` | Every playback action exposed by SwiftUI or CarPlay runs through the shared playback controller with identical semantics. System transport controls act on the player directly and their effects are processed through the same observation path. A surface may expose fewer actions but never a different version of one. | Confirmed product requirement (2026-08-31, revised 2026-10-04); `Overplay/Services/PlaybackController.swift`, `Overplay/CarPlaySupport/CarPlayCoordinator.swift` |
| `SURFACE-002` | Every observed player change is published as one snapshot to every Overplay surface within one observation cycle; system surfaces read the same player. Current track, playlist context, play state, position, outgoing-session evaluation and active-playlist projection must not diverge. | Confirmed product requirement (2026-08-31, revised 2026-10-04); `Overplay/Services/PlaybackController.swift` |
| `SURFACE-003` | Equivalent iOS/iPadOS and CarPlay actions use one controller decision, including in-intent jump versus new intent, resume versus restart, and failure handling. | Confirmed product requirement (2026-09-25); `Overplay/Services/PlaybackController.swift` |

Withdrawn requirements: `PLAY-001` (Overplay-owned shuffle/repeat) and `PLAY-002`
(windowed hand-off) — see History H-1 and H-2. `PLAY-006` (confirmed-mode
retention during pending transitions) is superseded by `PLAY-004` and
`PLAY-013`, because there are no pending transitions any more.

## Platform

- Current platforms:
  - iPhone on iOS 26 and later.
  - CarPlay through the iPhone app on iOS 26 and later.
  - iPad on iPadOS 26 and later.
- Planned platform:
  - A native Mac target on macOS 26 and later. No Mac target currently exists.
- Language: Swift 6.
- UI framework: SwiftUI.
- Persistence: SwiftData backed by iCloud/CloudKit for shared playlist,
  track, statistics, and retirement data.
- Device-local state: device-local files and `AppStorage` for the playback
  intent, playback cache and navigation state, none of which syncs between
  devices.
- Apple Music integration: MusicKit first; Apple Music API only where MusicKit
  cannot support the required operation.
- Playback: `ApplicationMusicPlayer` unless a technical limitation requires a
  different Apple framework.
- Design language: native Liquid Glass on each platform, using system
  materials, translucency, depth, adaptive layout, and modern SwiftUI
  animation.

## Platform Strategy

Overplay uses one shared SwiftUI app architecture across iPhone and iPad and
is intended to extend that architecture to Mac. Product rules, sync,
persistence, search, playlist mutation, playback
tracking, and retirement logic should live in shared services and models.
Platform-specific code should be limited to presentation shell, scene
configuration, keyboard/menu commands, entitlement differences, and media
integration differences.

### iPhone

iPhone is the focused playback and quick-triage experience.

- Use compact navigation with a dashboard-first flow.
- Keep Now Playing as the strongest visual surface.
- Prioritize fast actions: play, skip, retire, promote, sync.
- Support Lock Screen and remote transport controls (provided by the
  `ApplicationMusicPlayer` host, `PLAY-016`) and the CarPlay music player.

### iPad

iPad is the review and management experience as well as a playback device.

- Regular width uses `NavigationSplitView`; compact width falls back to the
  stacked dashboard flow.
- The sidebar provides Dashboard, One True Playlist, Triage, Retired,
  Search, History, and Settings.
- Sidebar selection is scene-local and the persistent mini-player remains
  available over detail content.

**Planned iPad refinements:** improve wide-screen playlist detail and Now
Playing coexistence; verify Stage Manager, Split View, and multiwindow state;
and add useful hardware-keyboard and pointer interactions.

### Mac — Planned

Mac is the power-user library management and background playback experience.

- Prefer a native SwiftUI Mac target rather than treating Mac as only a
  scaled iPad surface.
- Use sidebar navigation, resizable windows, toolbars, menu commands, keyboard
  shortcuts, context menus, and table/list layouts where they improve scanning.
- Support multiple windows for playlist management, history, and Now Playing
  where practical.
- Keep playback state local to the Mac and resilient when windows are closed.
- Support media keys and Now Playing metadata where available.
- Use Mac-appropriate spacing, hover affordances, focus rings, and selection
  behaviour.

### Shared target expectations

- iPhone and iPad read and write the same iCloud-backed Overplay data. The
  planned Mac target must join the same store.
- Each current and planned target must keep transient playback and selection
  state local to the device.
- A sync, promotion, retirement, restore, or settings change made on one device
  should eventually appear on the others.
- A play, pause, queue, currently selected screen, or current playback position
  change on one device must not control another device.
- Platform conditionals should be small and isolated.

## Product Model

### Linked playlists

Overplay tracks multiple Apple Music playlists:

- **One True Playlist**: the main playlist Overplay manages and plays by
  default. Tracks can be manually retired from this playlist.

  When no One True Playlist is linked, the playlist management UI offers two
  setup paths. The user can create a new Apple Music playlist named "Overplay"
  by default, or choose an existing Apple Music playlist. Choosing an existing
  playlist offers to copy its tracks into a new managed "Overplay" playlist so
  the app can write changes back going forward. If the user opts out of copying,
  Overplay links the source playlist as incoming only and does not attempt
  outbound Apple Music mutations for that playlist.

- **Triage bucket**: the single place where everything awaiting review lives.
  Overplay tracks skips and playthroughs against bucket items. Tracks can be
  manually promoted to the One True Playlist or manually retired from bucket
  playback. The bucket has no Apple Music playlist of its own and carries a
  reserved identifier instead, so it is never fetched or synced directly.

- **Triage sources**: contributing Apple Music playlists that feed the bucket.
  Each keeps its own sync bookkeeping, but owns no items and is never played.
  A track contributed by several sources is a single globally owned row.

- **Retired**: the third top-level browsing/playback collection, shared by OTP
  and Triage. Stored as bucket ownership plus `evictedAt`, never as another
  Apple Music playlist. Listening here counts normally without restoring items.

Each linked playlist stores:

- Apple Music playlist identifier, or the reserved bucket identifier.
- Display name.
- Role: `oneTruePlaylist`, `triageBucket`, or `triageSource`.
- Write policy: `managed` or `incomingOnly`.
- Last successful sync date.
- Last sync error, if any.
- Whether the playlist is active.

Exactly one active playlist has the `oneTruePlaylist` role, and at most one has
the `triageBucket` role. Selecting another main playlist demotes the previous
one to a triage source. The current UI can add and remove contributing
playlists from the triage sources screen; it does not rename linked playlists
or delete their Apple Music source playlists.

Source attachments record every playlist that contributed a song until that
source is explicitly unlinked. Remote song removal does not detach it. Multiple
sources protect a row until the last is removed. Source-free is a normal state.

After last-source removal, active Triage retains explicit manual/restore intent
or any recorded play/skip history, even if counters were reset. Untouched active
rows without explicit intent are deleted. Retired source-free rows with current
0 plays and 0 skips are deleted, regardless of manual intent or prior resets.
This also runs immediately on retirement and ordinary counter reset. A sweep
re-applies it at startup and after every background sync cycle, for retired rows
and deferred deletions that missed their trigger (`PLAYLIST-011`); each deletion
is recorded in history. It never deletes active Triage rows. Nonzero
counts and necessary stale-OTP suppression protect rows. Active OTP is never
deleted by Triage cleanup. Deleted songs may return on later intake; independent
history remains but offers no broken Restore action.

Deliberate source link/re-link revives older retirements into Triage without
resetting counts. Normal sync, including the Sync button, does not. The durable
link timestamp survives failed initial imports; newer retirement wins on retry.
Unlink/re-link invalidates older in-flight imports.
If a newer retirement deletes a 0/0 row while a source's first import is
pending or an ordinary fetch is already running, the source records a link-scoped exclusion. That import and its retries
cannot recreate the row; unlink/re-link discards the exclusion. No permanent
global retired-item tombstone is kept.

Pre-bucket installs stored the role raw value `triage`. Because roles are
stored as strings, retiring that role is a data change rather than a schema
change, so a one-shot migration runs at startup before any view reads a role.
It re-parents legacy triage items onto the bucket, merging counts where the
same track appeared in more than one triage playlist, and is idempotent and
derived from the stored value so re-running it cannot double-count. Merged
rows take the most recent eviction decision.

Issue #36 then converges track identities and merges item rows app-wide before
legacy cleanup. Active legacy OTP wins conflicts; remaining retired rows move
to the bucket. Counts are summed, source attachments/explicit intent preserved,
and stale OTP membership suppressed. For the sole historical phone dataset,
unowned legacy 0/0 bucket rows are deleted even with reset history; explicit
keep, active OTP and necessary suppression remain protected. Stored
`ownershipVersion` defaults to legacy zero; new initializers write one, so
repeated startup and late CloudKit delivery cannot apply the historical reset
exception to new rows. There is no versioned-schema migration framework.

### Track state

Overplay stores one item per song app-wide. Statistics travel with that row
between OTP, Triage and Retired. Contributing playlists are attachments,
independent of current location and explicit keep intent.

For every tracked playlist item, store:

- Stable Apple Music identifiers where available.
- Playlist identifier and playlist role.
- Playlist entry identifier where available.
- Title, artist, album, artwork, and duration snapshot.
- Skip and playthrough counts: a cache derived from the listen ledger
  (`COUNT-002`), never edited directly.
- Last played date.
- Last skipped date.
- Last seen in Apple Music sync date.
- Retirement state.
- Contributing source identifiers, explicit keep intent and prior-activity evidence.
- Stale OTP membership suppression and location-change intent.
- Created and updated dates.

Multiple source appearances share the same item, counts and retirement state.
Location-scoped remote playlist-entry identifiers are cleared or rewritten when
the row moves.

Within one linked playlist, a song identity may appear at most once. Duplicate
remote entries, repeated manual adds, and promotion of an already-present song
should collapse to the existing playlist item for that playlist.

### Track identity

Catalog resources, web library resources, and native MusicKit playlist items
can expose different identifiers for the same song. Persistent playlist intake
must establish the domain through the request that resolves the item, not ID
syntax or serialized play parameters. Normal sync and playlist copying share
one song-resolution boundary: a native library-song lookup resolves the observed
ID. A device's on-device library can lack songs that its account library and
playlists still hold, so when the native lookup finds nothing, a web library
request that returns exactly the observed ID resolves the song as that library
song, keeping the observed entry as the device's representation of it. Web
library requests are batched, 25 songs per request (`LOAD-001`): a lagging
device's library can miss a third of a playlist. An answer for an ID that was
not requested stops the fetch, because it cannot be attributed. Only
then does an explicit catalog request resolve songs absent from the library. The web
library resource and its catalog relationship establish the corresponding shared
identifiers. Native lookup mappings stay within the import operation; they are
not persisted as global aliases.

A missing library resource is unresolved identity. It is not equivalent to a
returned library song with an explicitly empty catalog relationship. A song that
none of the native lookup, the web library and the catalog can identify is
skipped by ordinary sync (`PLAYLIST-010`):

- The rest of the playlist syncs. The skipped song creates no track, and its
  existing row is untouched: it is not removed, retired, reset or moved.
- Reconciliation skips the steps that infer absence from a complete snapshot:
  replacing this source's entry provenance, and releasing stale-OTP
  suppression.
- The playlist keeps a sync error naming the count. That keeps it retrying each
  cycle and disables the remote-unchanged skip until every song resolves.
- When more than a fifth of the playlist's distinct songs are unidentifiable,
  something wider is wrong, and the fetch stops before reconciliation as before.
- Copying a playlist, and any other operation that rewrites from the snapshot,
  still stops on any unidentifiable song.

Optional ISRC/equivalent-recording suggestions
are resolved by duplicate review, not required for import; an unperformed candidate
lookup must not erase earlier candidate evidence.

Identifier fields are fill-and-heal only: an update may add a missing
identifier or replace a wrongly-domained legacy value, but a source that sees
only one domain must never erase the other. An explicitly returned empty library
catalog relationship may invalidate an earlier unverified catalog hint.

Duplicate track records describing the same song (legacy mirrored IDs, or
CloudKit insert races, which cannot enforce unique constraints) are collapsed
by an identity merge pass that runs at startup and after each sync. The
oldest record wins; playlist items and history events repoint to it, and the
keeper records each absorbed track UUID in `absorbedTrackIDs`. Listen ledger
events are never rewritten, so the keeper's derived counts include the donor's
events, including ones that arrive late from another device. When two items
for the same track collapse, retirement state follows the most recently
updated item and the count cache is recomputed. Merging never adds or discards
counts. The playback intent rewrites merged member track UUIDs in the same
pass.

### Album artwork cache

Overplay stores artwork source metadata in SwiftData, but not artwork image
bytes. `TrackRecord.artworkURLTemplate` remains the shared source of truth for
album art, and each device downloads artwork directly from the Apple Music CDN
as needed.

Artwork image files live in the local caches directory under
`Overplay/ArtworkCache`. They are disposable, are not synced through CloudKit,
and can be redownloaded from their source URL. A local JSON manifest tracks each
cached file's cache key, source URL, requested size, associated playlist IDs,
last access date, and byte size.

Artwork loading must not block playlist rendering or playback. Store actual
128-pixel thumbnails for rows, the mini player and CarPlay, and 512-pixel variants
for expanded artwork and recognition (longest edge, preserving aspect ratio).
The expanded player shows available 128 artwork while 512 loads. Lists may use
cached images and load missing artwork while scrolling. CarPlay track rows show
artwork with the playing indicator beside it.

Decoded images share a 24 MiB cost budget across playlists. Source downloads and
image processing are bounded and coalesced. Artwork failures cool down for 60
seconds. The disk cache has a default 250 MiB budget, including a 32 MiB recent
512-pixel budget. The current playlist's 128 thumbnails are protected; requested
files and protected thumbnails may exceed the nominal budget. Visible access
updates eviction recency. Theme recognition runs on player demand rather than
warming every changed song after sync; theme writes are batched.

## Sync Behaviour

All linked playlists should be periodically synced against Apple Music. The
user can also trigger sync manually.

For performance reasons, if a playlist has existing tracks, the UI should act
on the stored tracks as soon as possible, loading, scrolling, playing etc
and should initiate a sync in the background.

Playlist detail screens should use one shared UI with two row data sources:
non-playing playlists render from SwiftData records, while the currently
playing playlist may render from the playback controller's active in-memory
playlist projection. This projection is a fresh read model only; durable
membership, metadata, skip/playthrough counts, retirement state, history, and
settings are still written through SwiftData.

### Additions from Apple Music

When Apple Music contains a track that Overplay has not seen in a linked
playlist:

- Add or reactivate the local playlist item.
- Preserve any prior history if the same playlist item can be matched.
- Set `lastSeenInPlaylistAt`.
- Do not reset historical skip, playthrough, or retirement records.

### Removals from Apple Music

When a track that Overplay previously tracked is no longer present in the
linked Apple Music playlist:

- Leave the local playlist item in place.
- Preserve skip, playthrough, and retirement history.
- Keep the item playable unless it has been locally retired.

Overplay does not currently model Apple Music deletions as a separate local
removal state. Local retirement remains the only way to exclude a track from
Active playback.

### Local retirements

When Overplay retires a track locally:

- Always record a historic retirement event. The current data model may store
  this as an eviction event while Retired remains the user-facing term.
- Store the manual source where applicable.
- Move the track from the Active list to the bottom of the Retired list for
  that playlist.
- Exclude the track from future Active playback for that playlist.

Local retirement is authoritative. Every retirement of a song in a managed One
True Playlist also removes it from the Apple Music playlist, whichever surface
started it: a playlist row, Now Playing or CarPlay (`PLAYLIST-008`). Retiring
from Triage or from an incoming-only playlist is local-only. A failed, deferred
or unsupported remote deletion never rolls back the local retirement.

Overplay keeps the managed One True Playlist in Apple Music free of every song
it holds outside that playlist, meaning every row carrying the playlist's
stale-OTP suppression: retired songs, and duplicates merged into Triage.
MusicKit can only remove a song by rewriting the whole playlist from the
device's copy, and a device whose library lags iCloud would resurrect songs
deleted elsewhere or drop songs added elsewhere. So:

- Overplay reads the playlist's entries from iCloud through the web library
  API. Response types establish domains: `library-songs` are library IDs and
  `songs` are catalog IDs. A song is present when any of its identity
  references matches an entry.
- A rewrite runs only when the device's copy holds exactly iCloud's entries.
  Raw IDs are compared directly where the device reports web library IDs;
  otherwise each entry resolves through the shared song-resolution boundary.
  Every occurrence of the songs being removed is dropped; nothing else changes.
- When the copies differ, the songs stay in Apple Music and remain suppressed
  and retired in Overplay, and the user is told Apple Music will be updated
  after the next sync.
- A song that is removed, or already absent from iCloud's copy, releases its
  suppression and gets the retention rule at once, so a retired source-free
  0/0 row is deleted.
- MusicKit lets an app replace a playlist's contents only when that app
  created it, and Apple Music can stop recognising Overplay as the creator of
  an older playlist. When it refuses (`ICPlaylistUpdateErrorDomain` -1),
  Overplay records the refusal on the playlist and stops attempting edits. It
  keeps reading iCloud's copy, so a song removed by hand in the Music app still
  releases its suppression. Rebuilding the Apple Music playlist links a new,
  Overplay-created one and clears the refusal.
- An iPad app running on a Mac has no MusicKit playlist editing, and any edit
  crashes. A Mac never loads or edits the playlist; its removals wait for an
  iPhone or iPad.
- Retirement, duplicate merge, and every completed One True Playlist sync
  (periodic, manual or CarPlay) run the same operation, so deferred or failed
  removals are retried after each sync. A retry never fails the sync.

#### Rebuilding the Apple Music playlist (`PLAYLIST-009`)

Settings on iPhone and iPad offers **Rebuild Apple Music Playlist**, after a
confirmation. It explains when Apple Music has refused Overplay's edits. A
rebuild:

- Creates a new Apple Music playlist with the One True Playlist's name and
  "Managed by Overplay" description. It contains the active songs in Overplay's
  playback order; retired songs are left out. Apple Music adds only live
  MusicKit items to a playlist and refuses tracks decoded from saved playback
  data. So each song comes from the current playlist's own entries, matched by
  library ID, or else from the catalog, as promotion adds it. Songs with
  neither are skipped and reported; they stay in Overplay.
- If creation fails, Overplay keeps its current playlist and says that an empty
  playlist may have been left behind. MusicKit creates the playlist before
  adding songs, and cannot delete it.
- The new playlist's identifier is confirmed by a native lookup of its MusicKit
  ID, which on iPhone and iPad is the web library ID. Apple's library list can
  lag a new playlist. If the identifier cannot be confirmed, Overplay keeps its
  current playlist and reports the created playlist and its song count, so the
  user can delete it and try again.
- Relinks the same One True Playlist record to the new identifier, exactly as
  when MusicKit reissues one: source provenance, stale-OTP suppression, the
  selected playlist and the playback intent all follow it. The playlist
  becomes `managed`, and its recorded edit refusal is cleared.
- Changes nothing in Overplay when no song can be added or creation fails.
  Deletes nothing in Apple Music: the user deletes the older playlist in the
  Music app.
- Syncs the One True Playlist afterwards. A failed sync leaves the new link in
  place for the next sync to complete.

Rebuilding is deliberate. Overplay never recreates a playlist because it seems
to be missing, since a lagging or offline device cannot tell a deleted playlist
from one it has not loaded.

Retirement survives other devices (`LOC-001`). Each song is one CloudKit record,
and CloudKit keeps whichever device saved the whole record last. A device that
has not yet imported a retirement can therefore write the row back unretired
when it makes any routine background write, such as a playlist sync or a play
count update. History events are separate append-only records, so they survive.
After every import, and once library preparation finishes at startup, the
newest `evicted` or `restored` event for a song re-applies its decision if that
event is newer than the row's `locationChangedAt` and the row disagrees.
Re-applying a retirement restores stale-OTP suppression and runs the 0/0
retention rule, exactly as retiring does. The repair writes no new event and
stamps `locationChangedAt` with the event's own time, so every device converges
on the same state. A newest `promoted` event is left alone: promotion also adds
the song to the Apple Music playlist, so the next One True Playlist sync
restores it. Every path that changes retirement state stamps
`locationChangedAt`, including resetting all statistics.

### Apple Music entry identity and completeness

Linked playlist reads paginate MusicKit `Playlist.entries` before reconciling.
Every usable song snapshot preserves the entry ID, remote position, ISRC,
underlying song identity, and display/playback data. Remote occurrences are
source-scoped provenance on the one global item row; duplicate occurrences do
not create extra listening statistics or queue rows. Remote positions never
replace Overplay's display order. A successful source snapshot replaces
that source's current occurrence observations, independently of the retained
contributing-source attachments. Moves retain provenance; identity merges combine
it, source-ID healing rekeys it, and explicit unlink removes it.

Missing entry IDs remain missing; source/position distinguishes observations only,
not durable playback identity. Music videos are skipped for song intake but
retained, including their order, by playlist copies and rewrites. An unavailable
or unsupported item fails the entire sync/copy/rewrite before any remote-absence
inference. Missing relationships, missing or empty promised pages, repeated entry
IDs/overlapping pages, errors, and cancellation likewise fail closed. A previously
successful track-only sync must fetch entries once before the remote-unchanged
shortcut applies.

Entry play count and last-played date are retained with the source occurrence and
observation time and exposed to the shared playback-history reconciliation
boundary as diagnostic observations. They do not substitute for either side of
library-track proof and cannot award playthroughs or skips. Reliability and entry-ID
consistency across library/shared/catalog playlists remain physical-device checks.
This adds optional/defaulted provenance storage without a historical data migration.

### Periodic sync

After Apple Music becomes ready, automatic sync starts after a 10-second delay
and evaluates active linked playlists every 30 minutes. A playlist with a
successful sync less than 30 minutes old is skipped; a playlist with no prior
sync or a recorded error is retried. Catch-up cycles prioritize the currently
playing playlist, then the selected One True Playlist, then the remaining
playlists in stored order, with pacing between playlist operations.

The user can manually sync one playlist or all linked playlists. Selecting or
creating a linked playlist starts a background refresh. Successful search adds
and promotions write their local result immediately; search then syncs the
destination playlist when possible.

Sync must be idempotent. Running sync multiple times should not duplicate
tracks or erase history. A linked playlist must contain at most one local
playlist item per song identity; duplicate remote occurrences should collapse
to the first seen song identity, and manual add or promotion should reactivate
or reuse an existing playlist item instead of creating another copy.

If MusicKit reports a different library playlist ID than the one Overplay
stored (for example after `createPlaylist`), sync may heal the linked
`musicPlaylistID` when the playlist name uniquely matches a library playlist.
Ambiguous duplicate names should fail rather than relink silently.

## Promotion and Manual Add

### Promotion from the triage bucket

Tracks in the triage bucket can be manually promoted to the One True Playlist.
Contributing playlists are not promotion sources — they own no items.
Promotion should:

- Attempt to add the track to the linked Apple Music One True Playlist, unless
  iCloud's copy already holds it (for example, after a removal that could not
  run). When iCloud cannot be checked, add it.
- Move the existing local item into OTP on success.
- Preserve counts, timestamps, source attachments, explicit keep intent and history.
- Record a promotion event linking source playlist and destination playlist.
- Leave no second source or retired copy behind.

If Apple Music add-to-playlist fails, show a clear non-fatal error and do not
pretend the promotion succeeded.

### Search and manual add

Users can search Apple Music and manually add tracks to active linked playlists
whose write policy is `managed`. Incoming-only and inactive playlists are not
offered as destinations.

Add behaviour:

- User selects the destination playlist.
- Overplay attempts to add the track to the Apple Music playlist.
- On success, Overplay syncs that playlist or inserts the local item using the
  returned identifiers.
- On failure, Overplay displays a clear error.

The shared local manual-add boundary also supports Triage without a remote
write. It establishes explicit keep intent, reuses/revives the global item,
and never demotes an active OTP item. A new Triage search experience is separate
work. Moving from Retired to Triage uses the same explicit keep semantics.

OTP sync can promote an active bucket item, logging `promoted` with source
`sync`. It cannot revive retired rows or override stale-OTP suppression. An OTP
retirement, including failed or incoming-only remote removal, keeps suppression
until a complete successful OTP snapshot proves absence, or explicit promotion
supersedes it. Missing MusicKit track relationships or promised next pages are
errors, not complete empty snapshots. Reviving into Triage does not clear that protection.

## Play/Skip History

Overplay records per-track playthrough and skip counts. Counting is a layer on
top of playback (`COUNT-001`): it observes what the player did and records
outcomes afterwards. It never issues player commands, never delays or vetoes
one, and a counting failure never changes what is playing. Promotion from triage
and retirement from any playlist are manual user actions. Skip counts are
displayed as history only; they do not imply an automatic status.

### Defaults

```swift
skipThresholdPercentage = 50
minimumSkipListeningSeconds = 10
playthroughThresholdPercentage = 90
```

### Listening sessions

The session tracker is fed only by player observations: the current entry, its
attribution to a playback-intent member (see **Playback Engine**), the playback
status and the position. A session starts when an attributed entry becomes
current and ends when a different entry becomes current, the queue ends, or a
new playback intent replaces the old one. Each session is evaluated at most
once, after its end has been observed.

An unattributed entry has no session that can be counted. Its listening is
dropped with a diagnostic. Losing a count is acceptable. Stopping or
misdescribing playback to avoid losing one is not.

### Skip decision

A skip is counted when all are true:

- The session has not already been evaluated.
- The session is attributed to a playback-intent member whose track still has
  an item. Retired auditions count on the same path.
- The user listened for at least `minimumSkipListeningSeconds`, measured as
  witnessed listening time accumulated from consecutive position samples, not
  as raw playback position. Seeking or resuming mid-track contributes nothing.
- Playback progress is less than `skipThresholdPercentage`.
- The transition was not a natural completion — either the queue ended, or the
  last observed position was within three seconds of the duration.
- The transition did not move backwards. When the incoming entry precedes the
  outgoing entry in the player's queue order, the transition was a Previous
  from some surface, and it is not a skip.
- The observation is fresh: the last sample is at most five seconds older than
  the observed transition. Playback continues out-of-process while Overplay is
  suspended, and an unobserved interval must never produce a skip.

If the user skips after the skip threshold but before the playthrough
threshold, neither count changes. Sessions restored for display after a
relaunch are never evaluated.

### Playthrough decision

A playthrough is counted as soon as an attributed session's observed position
reaches `playthroughThresholdPercentage`, or when natural completion is
observed. Playthrough evaluation is position-based: seeking to or beyond the
threshold can count a playthrough. This is an intentional product rule, and
seeking still contributes nothing to the witnessed listening a skip requires.
Playthroughs and skips accumulate independently.

### Listen ledger (`COUNT-002`)

Every counted outcome is an immutable `ListenEvent` record in the shared store.
Records are inserted and never edited. The only deletion is an explicit
whole-database nuke.

- `kind`: `playthrough`, `skip`, `skipReset` (one track's skips),
  `statsReset` (every track), `baseline` (carried-forward counts), or
  `lineage` (this track absorbed the donor named in the session ID).
- `trackID`: the Overplay track UUID. Counts travel with the track, not with a
  playlist row.
- `sessionID`: an idempotency key. Two events with the same session ID and kind
  count once. Live sessions use `<local track UUID>@<session start time>`. Reconciled
  playthroughs use their proof key. Baselines use `baseline:<trackID>`, so two
  devices migrating the same data converge on one baseline; when they differ,
  the earliest (then lowest ID) wins, deterministically. Lineage uses
  `lineage:<donor UUID>`.
- `deviceID`, `occurredAt`, `source` (`playback`, `reconciled`, `migration`,
  `user`), optional `mechanism`, `playthroughDelta` and `skipDelta` (baseline
  only).

A track's counts are derived from the events for its own UUID plus every UUID
it has absorbed in an identity merge, transitively, from both the keeper's
`absorbedTrackIDs` and its immutable `lineage` events. Two devices merging
different donors into one keeper therefore keep both, even though the keeper's
list attribute is last-writer-wins:

- playthroughs = distinct playthrough sessions + baseline playthrough deltas,
  all after the latest `statsReset`;
- skips = distinct skip sessions + baseline skip deltas, all after the later of
  the latest `statsReset` and that track's latest `skipReset`.

`PlaylistItemRecord.skipCount` and `playthroughCount` are a materialized cache
of that derivation, written together with `countsDerivedFromLedger = true` and
the reset each count was derived after (`countsPlaysResetAt`,
`countsSkipsResetAt`). They are recomputed after local ledger writes and after
CloudKit imports (skipped when the store's event count is unchanged and nothing
was migrated). A marked row is joined with the local derivation, never simply
overwritten:
- a later reset wins outright;
- with the same reset, the higher count wins, because it is the more complete.

A row that only looks higher because this device is still missing events is
therefore never lowered, and the 0/0 retention rule and Apple play-count seeding
never act on counts that are merely in flight. A reset this device knows about,
newer than the one the row reflects, lowers it immediately. Two devices that hold the same events compute the same
values, so concurrent writes to the cache converge instead of losing
increments. Nothing ever increments, sums or zeroes the cache directly.

Merging duplicate items of one track needs no count arithmetic. Absorbing a
donor track records the donor UUID in the keeper's `absorbedTrackIDs` and writes
a `lineage` event. Events keep their original track UUID, and events arriving
late for the donor still count toward the keeper.

A playthrough that suspended-playback reconciliation already credited for the
current play (the item's last playthrough falls after this play began) is not
counted again when the controller later observes the same play.

Pre-ledger counts are carried forward as one `baseline` event per track. Only
rows the ledger has never written are pre-ledger: a row marked
`countsDerivedFromLedger` may have been synced from another device ahead of that
device's events, and migrating it would count those plays twice. Migration
runs at startup before any merge, before a track's first new event, and before
two identities are joined. Tracks that already have outcome events are not
migrated again.

History events are a separate, human-readable log with retention limits. They
are never the source of counts.

### Independent Apple play-count comparison

Playback surfaces display `Overplay/Apple plays` alongside the existing skip
count. The original threshold-based evaluation and reconciliation below keep
their existing behavior. The second total is seeded from the current Overplay
playthrough count at the first valid Apple library observation, then advances
by Apple's cumulative counter deltas. For example, one Overplay play and an
Apple counter of ten display `1/1`, equivalent to an effective baseline of nine.
Missing initial metadata displays `—`; it does not create a zero baseline.

Unresolved tracks also use a paginated local library scan, at most once every
six hours and never while the player is playing (`LOAD-001`). Matching prefers Apple identity aliases, then a unique ISRC
with compatible duration, then unique case/diacritic/whitespace-normalized title,
artist and album plus duration within two seconds. Conflicting ISRCs and ambiguous
metadata matches are rejected. Missing-count candidates still participate in
ambiguity checks. Metadata matches are scoped to the local track and do not
change playback aliases or authorize deduplication. A discovered library counter
ID becomes part of the persisted counter state for subsequent direct refreshes.

Shared playback reconciliation immediately requests a focused lookup when a
track starts playing with an unknown count, including externally initiated track
changes. This does not wait for the bulk refresh or its discovery cooldown.
It queries the track's IDs, then paginates a title search if still unresolved.
Title searches require identity or complete metadata matching; only a full scan
can prove ISRC uniqueness. Concurrent requests for the same track are coalesced,
and repeated misses retry at most once per minute. Playback is not blocked by
these lookups, and completed counts publish through the shared playback state.

The shared ApplePlayCountSyncService queries retained tracks in batches on
foreground, after playlist sync (including unchanged playlists), and at most
every fifteen minutes while the app runs. It skips periodic refreshes while the
player is playing or a playback failure is active (`LOAD-001`). Library observations are independent of playback
sessions, so no per-play HistoryEvent is synthesized. Listening outside
Overplay may contribute, and Apple controls counter propagation latency.

ApplePlayCountRecord stores immutable snapshots as separate CloudKit records,
with a device identifier, item identifier, published count, reset version, and
encoded counter evidence. No shared mutable counter blob is authoritative.
Reconciliation joins counter high-water readings and picks the earliest baseline
by observation time, breaking ties by its stable baseline identifier. Initial
credits merge by origin identifier, keeping the credit paired with the earliest
observation so intervening plays are not counted twice. Independent alias origins
sharing the same Apple counter also use the maximum rather than summing. Separate
counter credits remain additive. The join is associative, commutative, and
idempotent; new totals are calculated only after all observations are joined.
Mixed-initialization merges bind unobserved initial credits to known library IDs
before publishing the floor. Credits with unresolved identity are not assumed
independent: their addition waits for an observation whose aliases bind the seed.
The join still preserves the maximum existing floor while identity is unresolved.
Automatic deduplication captures each original seed identity before absorbing
TrackRecords or repointing items. First observation of a wholly unobserved merged
item seeds its combined current Overplay count and records covered origin IDs.
Coverage remains paired with the selected initialization credit during joins;
late original seed snapshots cannot add the covered credits a second time.

The display reads the highest published count in the current reset version.
A calculation can only raise that floor, including when late initialization
changes the canonical baseline. If Apple reports a lower value or resets its
counter, the display holds steady until the calculated total overtakes it.
New library identities start from their first valid observation. Missing,
negative, failed, duplicated, or out-of-order readings do not decrease the count.

Track merges publish a snapshot retaining both items' lineages. The repository
follows those lineages when reading evidence, so observations arriving for a
subsequently deleted donor remain discoverable. Published observations are never
rewritten or compacted during ordinary refreshes or merges. Indexed item lookups
keep display reads scoped to the relevant track. Nuke Database deletes this
evidence alongside the other app records.

Reset-only state without any observed counter continues to display `—` and stays
eligible for both discovery paths. The first usable reading after such a reset
seeds the then-current Overplay count; a real observed zero displays zero.
An explicit stats reset creates a new reset version, zeros its initial credits,
and rebases known counters at their high-water readings. Reset versions order by
timestamp and stable identifier. Earlier-version observations cannot undo the
reset, and requests started before a reset are discarded for that item. Successful
CloudKit imports reconcile the evidence in a fresh context and publish through
the shared playback controller, independently of MusicKit availability. Tests
simulate reordered delivery between independent stores; live CloudKit transport
still needs physical-device verification.

### Suspended-playback reconciliation

Playback continues out-of-process while Overplay is suspended, so the session
tracker cannot witness it. Skips are never reconstructed for suspended spans.
Playthroughs are recovered on wake (a background refresh grant, scene
foregrounding, or entering the background, which records the baseline
waypoint) under three proof rules. Anything ambiguous counts nothing.

- Point proof: the player's current entry, attributed to an intent member, is
  at or past `playthroughThresholdPercentage`.
- Continuity proof: between two waypoints, elapsed wall time accounts for the
  durations of every traversed intent member in submitted order, within a
  small per-boundary tolerance. Each completed member counts. This proof is
  available only while MusicKit reports shuffle explicitly off, because only
  then does the player follow the submitted order. Any pause, skip, stall,
  unknown duration, unattributed entry or intent change fails it.
- Music-library proof: a batched `MusicLibraryRequest<Track>` shows that the
  same library item's `playCount` increased and its `lastPlayedDate` advanced
  into the observed interval. Missing, stale, mismatched or failed data is
  neutral. At most 41 unresolved baselines (the current member plus 20
  following members in two windows) are kept for 24 hours. A qualifying advance
  credits at most one playthrough.

Recovered playthroughs are written to the listen ledger with source
`reconciled`, their proof mechanism (`pointObservation`, `wallClockContinuity`,
`musicKitPlayCount`), and a session ID derived from the proof. They also appear
in history with the proof mechanism. Double counting is prevented by the live
session's evaluated flag, the waypoint's counted-track ledger and ledger
session-ID idempotency.

Background entry flushes a local waypoint before awaiting library metadata.
Background refreshes submit a replacement request before reconciling, aiming at
the current track's playthrough-threshold crossing, with a 15-minute fallback.
iOS can reject or delay grants, so recovery never assumes per-track wakes.
Long unattended spans, delayed metadata and repeated plays can under-count by
design.

### Manual retirement

The user can manually retire a track from any linked playlist. Manual
retirement:

- Moves the same item to the global Retired collection, or deletes it under the
  unowned 0/0 rule.
- Records a manual retirement event.
- If retiring from a managed One True Playlist, attempts Apple Music removal.
- Falls back to local filtering if an attempted remote removal fails.

Retiring the current track from Now Playing (app or CarPlay) first marks its
session evaluated without a skip, then issues Next. Retiring any other track
leaves the live queue alone. If that track's entry is reached later in the same
intent, the controller issues Next when the entry is observed (`PLAY-015`).

Retired offers Move to Triage and Move to One True Playlist. Each moves the
existing row to the bottom of the destination order without resetting counts.
Move to Triage establishes explicit keep intent. Reset All Stats writes a
`statsReset` ledger event and keeps its existing retirement reset behaviour.
Resetting one track's skips writes a `skipReset` event.

## Shared vs Device-Local State

The SwiftData store is backed by iCloud so devices on the same account can
share:

- Linked playlist definitions.
- Track metadata snapshots and identity lineage.
- Playlist membership and retirement state.
- The listen ledger and the count cache derived from it.
- Retirement and promotion history.
- User-configurable playback-evaluation thresholds.

The following must remain device-local:

- The playback intent, including its member list (`PLAY-010`).
- The last observed playback position and play intent, for restore.
- The device playback cache of native MusicKit `Track` objects (`PLAY-017`).
- The suspended-playback waypoint.
- Current selected screen, playlist view and Now Playing UI state.
- The active playlist row projection.
- Transient sync and playback progress state, and diagnostics.

Window-specific navigation and presentation state uses `SceneStorage` or other
scene-local storage where a platform supports multiple windows. Two devices
share playlist, count and retirement data without controlling each other's
playback.

## Playback Engine

> **Direction (2026-10-04): a reliable music player first.** Playback is the
> core of the product. Deduplication, play/skip counting, Apple play counts,
> sync, artwork and curation are layers on top of it. A layer may read
> playback state. It may never gate, delay, veto or rewrite playback, and its
> failure must leave playback untouched. Approaches abandoned on the way to this
> design are recorded in **History: Abandoned Playback Approaches**. Read that
> section before changing anything here.

The engine rests on four rules:

1. **Overplay knows what it asked to play.** That knowledge is recorded before
   the queue is handed to MusicKit, and no observation can erase it
   (`PLAY-010`).
2. **The player is the authority on what is audible.** Overplay shows the track
   MusicKit reports, even when it cannot attribute it (`PLAY-011`).
3. **Every command is one direct call.** There are no confirmation loops,
   automatic queue replacements, automatic retries or command rejection
   (`PLAY-013`).
4. **Failure is visible and recoverable by the user.** Recovery is a bounded
   ladder run only when the user asks for it (`PLAY-014`).

### Playback intent (`PLAY-010`)

Starting playback records a playback intent:

- intent ID and creation time;
- the Overplay playlist reference (Apple Music playlist ID, or the reserved
  bucket ID) and scope (Active or Retired);
- the ordered members that were submitted. Each member holds the local track
  UUID, the playlist item UUID, every known Apple Music identifier for the
  track (catalog, library, confirmed aliases, and the IDs carried by the
  native `Track`), and title, artist, album, artwork and duration;
- the starting member.

The intent is written to a device-local file before the queue is submitted. It
is replaced only when Overplay submits a new queue, and cleared only by a
database reset. Errors, timeouts, unattributable entries, sync, CloudKit
imports and relaunches never clear or rewrite it. Two narrow edits keep its
references valid: an identity merge rewrites merged member track UUIDs, and a
One True Playlist change that reparents the playing collection's rows rewrites
the playlist reference.

### Player authority and observation (`PLAY-011`)

Overplay subscribes to MusicKit's queue and state change publishers. It
coalesces bursts and reads values after the publisher fires. Each observation
reads the current entry ID and item, the playback status, the position and
both modes. While the status is `playing`, a one-second sample reads only the
current entry ID, status and position. It drives witnessed listening and the
playthrough threshold, and it catches a missed entry change. Nothing in steady
state enumerates the queue. Paused, stopped and interrupted players are not
sampled. Observation stays installed, and foregrounding runs one observation
pass.

Every Overplay surface renders one observed state:

- display track: title, artist, album, artwork, duration, position, status and
  modes from the player's current entry. An entry whose item has not hydrated
  yet shows its attributed member's metadata when one is known. Otherwise it
  shows a neutral loading state. It never shows the previous entry's metadata;
- playlist context: the intent's playlist and scope;
- attribution: the intent member for the current entry, or none;
- Overplay attributes (counts, retirement state, available curation actions):
  from the attributed member's item.

### Attribution (`PLAY-012`)

When the current entry ID changes, or its item hydrates, the controller
attributes the entry to an intent member:

1. A per-intent entry cache, used only if the cached member still matches the
   reported item by identifier or metadata.
2. Any identifier reported for the item (including IDs from its play
   parameters) that appears in exactly one member's identifier set.
3. Normalized title and artist (case-, diacritic- and whitespace-insensitive)
   matching exactly one member, with durations within two seconds when both
   are known.

Ambiguous or unmatched entries are **unattributed**:

- the player-reported track is still displayed on every surface;
- Promote, Retire and Move actions are disabled for that entry;
- its listening is not counted;
- the playlist context, the intent and all other attributions are kept;
- one diagnostic is recorded per unattributed entry.

Attribution never clears state. A later hydration or a later entry can
attribute normally.

### Starting playback (`PLAY-005`, `PLAY-017`)

1. Build the members from SwiftData in the scope's display order
   (newest-added first, or newest-retired first for Retired).
2. Resolve each member's native `Track` from the device playback cache
   (`PLAY-017`), fetching missing library and catalog tracks in one batch
   each. A member whose library ID no longer exists in the account library
   (not on device, not in iCloud) is resolved from its catalog ID in one more
   batch; only a definite miss falls back, never a failed request. Members that
   cannot be resolved are left out of the queue and the intent, with an
   activity-log error naming them and a non-blocking status message. Starting fails only when the requested start
   member, or every member, cannot be resolved.
3. Persist the new intent.
4. Pause, submit the complete queue starting at the start member, and play.
   **Shuffle and Play** picks a random start member and then writes shuffle
   off and on to the loaded queue. MusicKit ignores shuffle written before the
   queue loads.

The device playback cache stores encoded native `Track` objects in the caches
directory, keyed by local track UUID. It survives relaunch, is never synced,
and can be rebuilt at any time.

### Selecting a track (`SURFACE-003`)

Selecting a track from any playlist list, in the app or in CarPlay, enters one
controller action:

- **The selected member is the current member:** resume if paused, never
  restart. With no live queue (after a relaunch or a stop), this resumes the
  intent at its saved position, exactly like Play.
- **The track is a member of the live intent (same playlist and scope):**
  enumerate the player's queue once, find the member's entry by attribution,
  set it as the current entry, and play. If no entry can be found, submit a new
  intent with the same scope starting at that member.
- **Otherwise:** start a new intent for the selected playlist and scope,
  starting at the selected track.

### Transport commands (`PLAY-013`)

Play, Pause, Next, Previous, Select, Shuffle and Repeat each make one MusicKit
call. Select also calls play. Commands are not confirmed, not serialized behind
each other, and not rejected while another is in flight. MusicKit receives them
in order. Displayed state changes only when the player is observed to change.
Controls are enabled whenever the player holds a queue, and Pause whenever it
is playing. Play with no live queue resumes the intent at its last attributed
member and position. With no intent, it starts the default playlist.

### Failure and recovery (`PLAY-014`)

A failed play, resume or queue submission, or a stall (status `playing`
while the position does not advance for 10 consecutive samples), sets one
shared playback failure with a message and start time. A failed Next or
Previous is logged and leaves playback as observed, because at the end of a
queue that is normal. The iPhone/iPad status
line shows it with **Try Again**, the primary control becomes Retry, and CarPlay
presents one alert per failure episode with **Try Again**. Witnessed progress or
a successful recovery clears any failure, including a command error after which
MusicKit started playing anyway.

Nothing retries automatically. When the user presses Play while a failure is
active, the controller runs a recovery ladder and stops at the first rung that
works:

1. `play()`.
2. `prepareToPlay()`, then `play()`.
3. Resubmit the intent from the current member at the last known position,
   then `play()`. That member's track is looked up again first, so cached
   play parameters MusicKit can no longer play are not resubmitted unchanged;
   if the lookup fails, the cached track is used.

A stalled player already reports `playing`, so a bare `play()` proves nothing:
a stall starts at rung 2. Each recovery gets a fresh stall window, and the
failure stays shown while a rung-3 resubmission prepares. A Play press while it
prepares supersedes it at rung 3, never rung 2 on the old queue. A more specific
failure from the resubmission itself is kept. A press within two minutes of an earlier recovery
starts one rung above the rung that last ran, so a failure that keeps coming
back reaches rung 3. Resubmitting the track that is playing continues its
listening session instead of judging it. Each Play press runs the ladder at most
once. If every rung fails, the failure
remains with guidance that Apple Music is not responding. While a failure is
active, periodic playlist sync, bulk Apple play-count refresh and artwork
maintenance pause, so Overplay adds no Apple Music load. Pause is never
disabled.

### Shuffle and repeat (`PLAY-004`)

MusicKit owns both. A surface's request is written straight to the player, and
the displayed state is whatever is then observed. An unknown (`nil`) report
keeps the last confirmed value. The repeat control toggles off and repeat-all.
Repeat-one set elsewhere is shown as not-all. Turning shuffle on or off never
reorders, replaces or restarts the queue.

### Queue end

When the player reports no current entry and stops after an attributed session
was observed near its end, that session counts as a natural completion and
playback stops. The intent stays. Play then resubmits it from its first member.
If the last observation is stale (the end happened while Overplay was
suspended), the end is treated the same way and is not a failure. A fresh stop
mid-track is a failure: the current member and position are kept, so Play
resumes there. With repeat-all on, MusicKit loops the queue and no queue end is
observed. Under repeat-all, a wrap from the last entry to the first is
forward and a move from the first to the last (in a queue of three or more) is
backward. Without repeat-all, queue order alone decides.

### Same song, new entry ID

MusicKit can re-issue entry IDs for the song that is playing, for example after
a mode change. When the incoming entry is the same member as the outgoing
session, or its item has not hydrated yet, and the position is continuous
(within three seconds, at least one second in), the session moves to the new
entry instead of ending. An unconfirmed carry-over is checked when the item
hydrates. If it turns out to be a different song, the carried session ends
then and a new one starts, with the new song's duration. If it is still
unconfirmed after ten seconds, its listening is no longer attributed, but a
later hydration as a different song still splits it. When the first entry of a recovery or resume
resubmission is not the track being resumed, the carried listen is dropped,
never judged.

### Concurrent starts

Every start or selection supersedes any earlier one still preparing. An older
start that finishes preparing later is dropped, and its post-play steps never
touch the newer queue.

### Membership changes during playback (`PLAY-015`)

Sync, manual add, promotion, retirement, restore and source changes never
mutate the live MusicKit queue:

- additions appear at the next playback start;
- retiring the current track from Now Playing issues Next;
- an entry whose member has left the intent's scope (retired from Active, or
  restored from Retired) is skipped with Next when it is observed becoming
  current. Its session is marked evaluated without a skip. An entry is
  checked each time it becomes current, so a track retired after it played is
  skipped on the next repeat-all lap. It is checked once per visit, never after
  a mid-song carry-over, and skipped at most once per intent, so a wrap over
  out-of-scope entries cannot loop. A failed lookup is never out of scope. A
  member whose track was merged away on another device follows its keeper (by
  lineage), and the intent is rekeyed, instead of being skipped. When the item,
  the track and any lineage are all missing (a merge still arriving), the entry
  is unknown: it is not skipped, and it is checked again on its next
  attribution.

### Launch and restore

The intent, last position and play intent are loaded at launch, before and
independently of iCloud library restoration:

- **The player still holds a current entry:** it is attributed and observation
  resumes.
- **The player holds nothing:** the restored member is shown paused at its saved
  position. A saved position belongs to its own track: if that track is no
  longer in the intent, the intent resumes from its start at 0. An identity
  merge rewrites the resume point along with the intent. Play resubmits the intent from that member and seeks to the saved
  position when it is more than 5 seconds from either end of the track.

Restored sessions are never evaluated. Play, Pause, Next, Previous and resume
work before the library is restored. Browsing, curation and ledger writes wait
for restoration, and listening before then is not counted.

### System Now Playing and remote commands (`PLAY-016`)

`ApplicationMusicPlayer` is hosted out of process by the system media service,
which publishes Now Playing for Overplay. Lock Screen, Control Center, headset,
media-key and CarPlay transport controls act on that player directly.
Overplay therefore:

- does not write `MPNowPlayingInfoCenter`;
- does not register `MPRemoteCommandCenter` transport handlers or enable and
  disable those commands;
- observes every resulting change through the same observation path as its own
  commands.

A device-local diagnostic setting, **Mirror Now Playing from Overplay**
(default off), exists only to verify CarPlay behaviour on new iOS releases.
When it is on, Overplay publishes metadata derived solely from the observed
player state and registers transport handlers that call the player directly,
with no gating. Shipping it on requires an explicit spec change backed by
device evidence.

### Active playlist projection

While playback is active, the controller maintains a read-only projection of
the playing collection's rows (stable item and track IDs, display metadata,
artwork source, counts, retirement state, current row). The current row comes
from attribution. The projection is refreshed after shared mutations and ledger
writes, and discarded when another collection starts. Playlist views use it only
for the matching collection and scope, and otherwise read SwiftData. A failed
refresh falls back to SwiftData.

## Cross-Surface Playback Consistency

Cross-surface consistency is a release-blocking product invariant.

- **One source of audible truth.** System surfaces render the player host's Now
  Playing. Overplay surfaces render the controller's observation of the same
  player. They cannot disagree about the audible track, position, status or
  modes. Overplay-only attributes come from the attribution of that same entry.
- **One action per intent.** Equivalent SwiftUI and CarPlay actions call the same
  controller method. Track selection, resume-versus-restart, intent creation and
  failure handling are decided in the controller, never in an adapter.
- **One path for every change.** There is no separate handling for changes
  Overplay made versus changes another surface made. Every track change is
  processed when it is observed: the outgoing session is evaluated, attribution
  runs, and the observed state is published.
- **No optimistic state.** A surface never shows the result of a command before
  the player is observed to change. A failed command produces the shared
  playback failure, never a different playback state.

### Convergence contract

Overplay state follows a player change within one observation cycle: the next
coalesced publisher delivery, or at most one second while playing. Transitions
are processed in order:

1. Read the player's current entry and status.
2. Close and evaluate the outgoing session exactly once.
3. Attribute the incoming entry.
4. Publish the display track, attribution, counts, actions and active-playlist
   row.

Convergence never depends on playlist sync, SwiftData query refresh, view
recreation, CarPlay template replacement or manual refresh.

### Acceptance gate

Every playback change must be tested through the controller's public actions
against a fake player that can:

- re-issue every entry ID after submission and after a mode change;
- report item IDs from the other identifier domain than the one submitted;
- hydrate items late, or never;
- throw from `play()`, `prepareToPlay()` and skips, or block for longer than a
  second;
- change the current entry with no Overplay command (an external surface);
- report the queue in shuffled order.

Each case must show that the intent survives, the displayed track is the
player's, the outgoing session is evaluated at most once against the right
track, and no queue replacement happens without a user action. Device
verification on My Mac (Designed for iPad) covers live MusicKit. CarPlay
hardware covers Now Playing ownership, transport and the custom buttons.

## Required Screens

Screens are adaptive rather than separate products. Compact width uses stacked
navigation from the dashboard. Regular width uses a `NavigationSplitView`
sidebar for Dashboard, Search, History, Settings, linked playlists, and
playlist detail. Native Mac presentation is planned.

### Permission screen

Purpose: handle Apple Music permission and subscription readiness.

Show:

- Apple Music authorization state.
- Subscription/capability state when available.
- Connect Apple Music action.
- Settings guidance when permission is denied.

Platform notes:

- iPhone and iPad use the same full-screen onboarding surface.
- A direct action to open system Settings after denial is not implemented.
- **Planned Mac:** use a compact window-friendly state view with clear system
  settings guidance.

### Playlist management screen

Purpose: manage linked Apple Music playlists.

Required capabilities:

- Choose the One True Playlist.
- Add and remove the triage bucket's contributing playlists.
- Search/filter Apple Music library playlists.
- Show playlist artwork, role, track count, and sync status.
- Manually sync one playlist or all playlists. Bulk sync skips the bucket,
  which has no remote playlist to fetch.

Platform notes:

- iPad exposes playlist management in the regular-width sidebar/detail flow.
- **Planned Mac:** expose common actions through toolbar items, context menus, and
  menu commands.

### Dashboard

Purpose: provide three entry points: One True Playlist, Triage and Retired.

Show:

- One True Playlist row, or a link to configure it when absent.
- Triage bucket row, including on a fresh install and after its last
  contributing playlist is removed.
- Global Retired row, including when empty.
- For each row: representative artwork, role/current-playback icon, total
  tracked count, source, last-sync status, and write policy.
- Link to the triage sources screen, labelled with the contributing count.
- Settings action.

Platform notes:

- iPhone uses the compact stacked dashboard.
- iPad uses the same dashboard content within its split-view detail.
- Rich summary counts, triage queues, and direct play/sync/search/history
  actions remain roadmap work.
- **Planned Mac:** favor dense, sortable, scan-friendly summaries.

### Playlist detail

Purpose: inspect any linked playlist.

Show:

- Separate top-level OTP, Triage and Retired destinations, with no per-playlist
  Active/Retired picker.
- Active tracks in display order: newest-added first, independent of shuffle.
- Retired tracks ordered by most recent retirement and
  playable as a playlist context from iOS.
- Skip and playthrough counts.
- Retirement state.
- Promote action for triage bucket tracks.
- Manual retire/remove action for active tracks.
- Move to Triage and Move to One True Playlist for retired tracks.
- Search/add action scoped to that playlist.

Playlist-row taps follow the shared **Action routing and playlist-selection
parity** contract, including live-queue reuse and resume without restart.

Platform notes:

- iPad currently reuses the adaptive list in split-view detail.
- **Planned Mac:** support context menu actions for promote, retire, restore, and
  reveal in Apple Music where possible.

### Now Playing

Purpose: playback UI and skip/playthrough tracking.

Show:

- Artwork.
- Title, artist, album.
- Playlist context.
- Progress.
- Playthrough count versus skip count.
- Playback controls.
- Manual retire action for active tracks.
- Move to Triage and Move to One True Playlist for retired tracks.
- Promote action when playing from the triage bucket.

Now Playing displays the player-reported track (`PLAY-011`). When the
current entry is unattributed, the curation actions are disabled rather than
hidden. The standard media controls call the shared playback controller. A
shared playback failure is shown with a Play action that runs the recovery
ladder (`PLAY-014`).

Platform notes:

- iPhone should keep Now Playing immersive and touch-first.
- iPad uses the same persistent mini-player sheet and expandable Now Playing
  surface as iPhone.
- **Planned Mac:** support a compact mini-player style window in addition to the
  full Now Playing view where practical.

### CarPlay music player

Purpose: provide the in-car playback and browsing surface through CarPlay
templates connected to the shared playback controller.

Show:

- A row for the One True Playlist, opening its track list. There is no
  one-tap entry point above it: two similar-looking rows is one too many for
  a driver to disambiguate.
- The triage bucket in a separate section, opening the same track
  list.
- Tracks in newest-added or newest-retired display order, independent of shuffle.
- Global Retired as its own root destination, playable directly from CarPlay.
- Current track title, artist, album, and artwork where CarPlay templates
  support it.
- Play, pause, next and previous, provided by the system Now Playing template
  and acting on the player directly (`PLAY-016`).
- Direct Retire button in Now Playing for active tracks.
- Direct Move to Triage button in Now Playing for retired tracks.
- Direct Promote button when the current track belongs to the triage bucket.
- An Up Next button that returns to the root menu.

Track selection follows the shared **Action routing and playlist-selection
parity** contract used by iOS/iPadOS; CarPlay does not choose its own jump,
restart, or queue-replacement strategy. The root menu offers no manual refresh: every
list updates in place from shared playback state and from library changes made
on the phone. A playback action that fails must report that failure rather than
presenting Now Playing as though it succeeded.

Platform notes:

- CarPlay belongs to the iPhone app target and should use CarPlay scene
  configuration.
- CarPlay templates should remain thin and delegate playback, queue building,
  metadata, and command handling to shared services.
- The iPhone/iPad SwiftUI shell does not import or depend on CarPlay-specific
  types. The same isolation is required for the planned Mac target.

### Search

Purpose: search Apple Music and add tracks to an active managed playlist.

Show:

- Search field.
- Results with artwork, title, artist, and album.
- Destination playlist selector.
- Add action.

Platform notes:

- iPad currently uses the shared search list in split-view detail.
- **Planned Mac:** support faster triage with keyboard focus, return-to-add
  where appropriate, and persistent destination selection.

### Retirement and history

Purpose: show historic retirements, removals, and promotions.

Show:

- Track.
- Playlist.
- Event type.
- Manual source where applicable.
- Triggering skip count or manual source.
- Date.
- Remote Apple Music mutation status.
- Suspended-playback recovery totals and proof-mechanism breakdown.
- Reconciliation proof mechanism on each recovered playthrough.
- Restore/reactivate action where appropriate.

History survives sync, relaunch, and iCloud sync within its retention policy.
The view loads predicate-filtered pages of 100 events with an explicit Show
More action. `skipIgnored` events expire after 30 days; all other events expire
after 365 days. Startup cleanup deletes at most 500 expired events per run.

Platform notes:

- iPhone and iPad expose the same menu filter without hiding the event list.
- **Planned Mac:** use a sortable, filterable table when practical.

### Settings

Purpose: configure behaviour.

Settings:

- Selected One True Playlist and link-management navigation.
- Skip threshold percentage.
- Minimum listening time before skip can count.
- Playthrough threshold percentage.
- Reset all Overplay skip counts, playthrough counts, retirement state, and
  legacy state without changing Apple Music playlist contents.
- Nuke all Overplay SwiftData records locally and save those deletions for
  iCloud propagation, then recreate default settings and clear local playback
  state. Apple Music playlists are not deleted.
- Run MusicKit authorization, playlist-access, and playback-readiness
  diagnostics.
- Diagnostic, device-local: **Mirror Now Playing from Overplay** (default off,
  `PLAY-016`).

There is no separate reset-local-playback-state control. **Planned Mac:** expose the settings
window through the standard app settings command as well as in-app navigation.

## Services

### MusicAuthorizationService

- Request Apple Music authorization.
- Expose permission and subscription capability state.
- Provide clear failure states for UI.

### PlaylistSyncService

- Fetch Apple Music library playlists.
- Create a managed One True Playlist in Apple Music.
- Copy tracks from a source Apple Music playlist into a new managed One True
  Playlist when requested.
- Fetch tracks for each linked playlist.
- Reconcile additions. Remote removals leave the local item in place with
  its history preserved (see "Removals from Apple Music").
- Stamp `lastSeenInPlaylistAt` on every sighting (refreshed at most daily
  for unchanged items).
- Preserve history. Never touch the live playback queue (`SYNC-002`).
- Publish sync status.

### PlaybackController

The single owner of playback (`PLAY-010`–`PLAY-017`):

- builds, persists and restores the playback intent;
- submits queues and issues single transport commands;
- observes the player and publishes the observed state;
- attributes the current entry;
- feeds the listening-session tracker;
- runs the user-initiated recovery ladder;
- applies curation commands for the current track (retire, promote, restore).

It contains no queue correlation, confirmation loops, order stores or system
Now Playing publication. It depends on MusicKit only through the small
`PlaybackPlayer` protocol, so tests can drive every failure mode.

### PlaybackIntentStore and DevicePlaybackCache

- `PlaybackIntentStore`: a device-local JSON file holding the intent and the
  last observed position and play intent.
- `DevicePlaybackCache`: encoded native `Track` objects on disk in the caches
  directory, keyed by local track UUID, resolved in batches, with per-track
  failure tolerance.

### ListeningSessionTracker and PlaybackSessionEvaluationService

- `ListeningSessionTracker` (pure): turns observations into sessions, witnessed
  listening and transitions (forward, backward, natural completion, intent
  change).
- `PlaybackSessionEvaluationService`: applies the skip and playthrough rules
  and writes outcomes through the listen ledger.

### ListenLedger

- Append `ListenEvent` records, idempotent by session ID.
- Derive counts for a track and its absorbed identities, honouring reset
  events.
- Recompute the item count cache after writes and CloudKit imports.
- Write idempotent migration baselines.

### TrackActionService / EvictionEngine

- Manually retire or restore items from any linked playlist.
- Record retirement and listening history events.
- Route count changes (outcomes, single-track skip reset, reset all) through the
  listen ledger. Never edit counts directly.

### PlaylistMutationService

- Add tracks to managed linked Apple Music playlists.
- Promote tracks from the triage bucket to a managed One True Playlist and
  move the same global item on success without retaining a source copy.
- Return explicit success/failure results.

### SearchService

- Search Apple Music catalogue.
- Return lightweight result models.
- Support manual add to active managed linked playlists.

### SystemNowPlayingBridge

- By default, does nothing: the `ApplicationMusicPlayer` host owns system Now
  Playing and transport commands (`PLAY-016`).
- With the diagnostic mirror enabled, publishes metadata derived only from the
  controller's observed player state, and registers transport handlers that
  call the player directly with no gating.

### PlatformShell

- Provide the root navigation appropriate to each target.
- Share the same view models and services.
- Own platform-specific menu commands, keyboard shortcuts, toolbar placement,
  window commands, and scene setup.
- Keep platform branching out of business logic.

## Persisted Data Model

Generation 2 uses new persistent entity names (`LibraryPlaylistV2`,
`LibraryTrackV2`, `LibraryMembershipV2`, `LibraryHistoryV2`,
`LibrarySettingsV2`, `LibraryAppleCountV2`, `LibraryListenV2`). Existing source-level type names
below are aliases, not legacy database entities. The configuration-preserving
cutover protocol is specified in “Datastore generation 2” below.

### PlaylistRecord

- `id: UUID`
- `musicPlaylistID: String`
- `name: String`
- `role: PlaylistRole`
- `writePolicy: PlaylistWritePolicy`
- `isActive: Bool`
- `lastSyncedAt: Date?`
- `lastSyncError: String?`
- `sortOrder: Int`
- `createdAt: Date`
- `updatedAt: Date`

### TrackRecord

- `id: UUID`
- `catalogID: String?`
- `libraryID: String?`
- `title: String`
- `artistName: String`
- `albumTitle: String?`
- `artworkURLTemplate: String?`
- `durationSeconds: Double?`
- `libraryScope: String`
- `confirmedAliases: [MusicResourceReference]` (domain, scope, resource value)
- `isrc: String?` and `equivalentCatalogIDs: [String]` (review evidence only)
- `absorbedTrackIDs: [String]` (UUIDs of donor tracks absorbed by identity
  merges; their ledger events count toward this track)
- `createdAt: Date`
- `updatedAt: Date`

Artwork image bytes and native MusicKit playback objects are excluded from
SwiftData and CloudKit. `musicKitPlaybackData` reads the device playback cache
(`PLAY-017`), which is stored on disk in the caches directory. Queue preparation
reloads missing native objects from the typed library or catalog endpoint in
batches. A cached object whose ID is no longer the record's library ID (or,
without one, its catalog ID) is outdated, because a song removed and re-added
or re-matched by sync gets a new ID, and is reloaded the same way; if that
fails, the outdated object is still used. Songs that cannot be resolved are omitted from the queue with a
diagnostic and a status message.

### Artwork cache manifest

Local JSON file only:

- `cacheKey: String`
- `sourceURL: String`
- `pixelSize: Int`
- `associatedPlaylistIDs: [String]`
- `lastAccessedAt: Date`
- `byteSize: Int`
- `fileName: String`
- Playlist usage dates for cache eviction.

### PlaylistItemRecord

- `id: UUID`
- `playlistID: UUID`
- `trackID: UUID`
- `musicPlaylistEntryID: String?`
- `sortOrder: Int` (legacy persisted value; display order comes from dates)
- `skipCount: Int` and `playthroughCount: Int` (cache derived from the listen
  ledger, recomputed after writes and imports; never edited directly)
- `countsDerivedFromLedger: Bool` (set with the cache; such rows are never
  migrated as pre-ledger counts)
- `countsPlaysResetAt: Date?` and `countsSkipsResetAt: Date?` (the reset each
  cached count was derived after, used to join rows across devices)
- `lastPlayedAt: Date?`
- `lastSkippedAt: Date?`
- `lastSeenInPlaylistAt: Date?`
- `evictedAt: Date?` (local retirement timestamp in current code)
- `evictionReason: EvictionReason?` (retirement reason in current code)
- `evictionSource: EvictionSource?` (retirement source in current code)
- `createdAt: Date`
- `updatedAt: Date`

### ListenEvent (`LibraryListenV2`)

- `id: UUID`
- `trackID: UUID`
- `kindRawValue: String` (`playthrough`, `skip`, `skipReset`, `statsReset`,
  `baseline`, `lineage`)
- `sessionID: String` (idempotency key)
- `deviceID: String`
- `sourceRawValue: String`
- `mechanismRawValue: String?`
- `playthroughDelta: Int` and `skipDelta: Int` (used by baselines)
- `occurredAt: Date`

Inserted only, never edited. Deleted only by Nuke Database.

### HistoryEvent

- `id: UUID`
- `playlistID: UUID?`
- `trackID: UUID?`
- `eventType: HistoryEventType`
- `source: HistoryEventSource`
- `reconciliationMechanism: PlaybackReconciliationMechanism?`
- `skipCountAtEvent: Int?`
- `positionSeconds: Double?`
- `durationSeconds: Double?`
- `progressPercentage: Double?`
- `remoteMutationStatus: RemoteMutationStatus?`
- `message: String?`
- `createdAt: Date`

### OverplaySettings

- `id: UUID`
- `completedRebuildID: UUID?` (transactional restart receipt)
- `selectedPlaylistID: String?`
- `selectedPlaylistName: String?`
- `skipThresholdPercentage: Double`
- `minimumSkipListeningSeconds: Double`
- `playthroughThresholdPercentage: Double`
- `createdAt: Date`
- `updatedAt: Date`

The obsolete `protectKeptTracks` setting and playlist-item `protected` flag
have been removed, along with the controller and presentation paths that read
them. They existed only to shield tracks from automatic eviction, which no
longer exists.

## Edge Cases

- Apple Music permission denied or restricted.
- Authorized user without Apple Music playback capability.
- No library playlists.
- One True Playlist deleted or renamed in Apple Music.
- Contributing triage playlist deleted or renamed in Apple Music.
- Playlist contains unavailable, cloud-only, or local-only tracks.
- Same song appears in multiple playlists.
- Same song appears more than once in one playlist.
- Track has no artwork or duration.
- User skips immediately after playback starts.
- User skips after the skip threshold.
- Natural completion must not count as skip.
- Network failure during sync, search, add, promotion, or deletion.
- Remote playlist mutation succeeds but later sync returns stale data.
- Remote playlist mutation fails after local retirement.
- Retired tracks are restored while another surface is showing the same
  playlist.
- OTP, Triage and Retired destinations are switched repeatedly while playback is active.
- A Retired playlist is started on iOS while CarPlay is connected.
- iCloud data arrives while a device is actively playing.
- The same iCloud account uses Overplay on iPhone and iPad at the same time.
- Two iPad windows show different playlists simultaneously.
- A hardware keyboard or media key command arrives while a modal sheet is open.
- Platform-specific MusicKit capability differs or is temporarily unavailable.
- MusicKit re-issues queue-entry IDs, reports a different identifier domain
  than was submitted, or never hydrates an entry's item.
- A MusicKit call takes several seconds, or fails repeatedly with
  `MPMusicPlayerControllerErrorDomain` errors.
- The app is relaunched while the out-of-process player is still playing.
- Two devices count plays of the same track concurrently, or one device counts
  while another merges that track.
- The library has not finished restoring from iCloud when the user starts
  playback, including in CarPlay.

## Explicit Non-Goals and Deferred Work

The following are not requirements of the current product:

- Native Mac target, Mac windows, menus, tables, and media-key integration.
- Widgets, Dynamic Island, or separate watch surfaces.
- Rich dashboard summaries such as recent promotions, unreviewed queues, or
  high-skip queues.
- A separate reset-local-playback-state control or a direct deep link to
  system Settings after authorization denial.
- CarPlay skip-history-only browsing.
- Overplay-authored `MPNowPlayingInfoCenter` metadata or artwork. The
  `ApplicationMusicPlayer` host publishes system Now Playing (`PLAY-016`).
- Appending sync additions to the live queue, or any other live queue mutation
  driven by membership changes (`PLAY-015`).
- Automatic playback retries or queue replacements (`PLAY-013`, `PLAY-014`).
- User-facing keep/protection behavior, and the automatic eviction it
  existed to guard against. Eviction is a manual decision. Persisted
  controller APIs are obsolete implementation debt and must not be treated as
  product behavior.

## Known Defects and Verification Gaps

- The 2026-10-04 playback-core rewrite (`PLAY-010`–`PLAY-017`, `COUNT-*`,
  `LOAD-*`) needs physical-device acceptance. Run it on My Mac (Designed for
  iPad) for live MusicKit, and on iPhone with CarPlay hardware for system Now
  Playing ownership, transport controls and the custom buttons.
- **iOS 27 CarPlay Now Playing (unverified).** A developer report (Apple
  forum thread 847151) says CarPlay's `CPNowPlayingTemplate` on iOS 27 reads
  only the app's own Now Playing client and does not follow
  `ApplicationMusicPlayer`'s host. If CarPlay shows stale or empty Now Playing
  on the user's iOS version, verify with the diagnostic mirror (`PLAY-016`)
  before changing the default.
- **Mixed versions and rollback.** All devices on an account must move to the
  listen-ledger build together. A device still on an older build increments the
  count cache directly. Once an upgraded device re-derives that row, those plays
  are dropped. Rolling back after ledger events exist leaves rows marked as
  derived, and upgrading again re-derives them from the ledger. There is no
  supported rollback once events are written.
- In a two-entry queue under repeat-all, Previous from the second entry cannot
  be told apart from Next wrapping to the first. It is judged forward, so it can
  count a skip.
- Accepted at merge of the rewrite (PR #62, round-4 review), in priority order:
  - **Repeat-all laps:** a retired track is skipped on reach only on the first
    lap; later laps play it, contrary to Manual retirement.
  - **Merge delivery order:** if a merged track's item update arrives before its
    lineage event and before the donor track's deletion, the track is skipped
    on reach as if it had left the scope.
  - **Same-entry replays:** repeat-one, a one-entry repeat-all queue and
    scrubbing back to the start do not count another play or skip.
  - **Count cache across devices:** the join trusts the reset date stored on
    the synced row. If CloudKit truncates dates or merges a conflicting count
    and reset date field by field, a row ahead of its events can be lowered on
    the device that reset, or a reset undone on one row. Unverified on device.
  - **Cache above the ledger:** competing baselines from two devices keep the
    higher cached count, so a displayed count can stay above the derived one.
  - **Import cost:** every CloudKit import scans all items and, after any local
    play or skip, re-derives all counts on the main actor.
- Whether `CPNowPlayingShuffleButton` and `CPNowPlayingRepeatButton` reflect
  MusicKit's modes without Overplay publishing remote-command state is
  unverified on hardware.
- CarPlay has two open playback-surface reports from before the rewrite:
  custom Promote, Retire and Restore controls absent on hardware
  ([GitHub #22](https://github.com/xurble/overplay/issues/22)), and the shuffle
  button toggling several times after a track change
  ([GitHub #28](https://github.com/xurble/overplay/issues/28)). Both must be
  re-checked after the rewrite, because the second Now Playing client
  (History H-7) is a plausible cause of #28.
- The distinction between CarPlay Back and the enabled Up Next button needs
  hardware investigation
  ([GitHub #27](https://github.com/xurble/overplay/issues/27)). Intended behaviour
  is Back by one level and Up Next to the root playlist menu.
- Suspended-playback recovery is bounded by the sampled library window and
  metadata availability. Physical-device counter propagation and the necessity
  of `audio` background mode remain unverified after the lifecycle fixes for
  [GitHub #9](https://github.com/xurble/overplay/issues/9). Skips remain
  deliberately unreconstructed for suspended intervals.
- Keep/protection has been removed. It existed only to shield tracks from
  automatic eviction, which no longer exists: eviction is entirely manual.

## CarPlay

CarPlay is the primary product surface, not a companion to the phone UI. Most
listening happens there, so every playback and curation action a driver needs
has to be reachable in the car — an action available only on the phone is,
for practical purposes, unavailable.

The app target has the CarPlay audio entitlement and declares a CarPlay
template application scene.

The app architecture keeps playback independent of SwiftUI views, so CarPlay
templates use the same shared controller as the phone UI. System Now Playing
and transport commands belong to the `ApplicationMusicPlayer` host
(`PLAY-016`).

Navigation is three levels and nothing more (`CAR-001`): the root lists the
One True Playlist, Triage and Retired, a collection lists its
tracks, and a track opens Now Playing. There are no shuffle rows and no
one-tap play row — a driver should not have to read a menu to tell two
similar entries apart.

CarPlay supports:

- Browse the One True Playlist, Triage and global Retired.
- Browse playlist tracks with playthrough and skip totals in row detail.
- Select a track to play it through the shared selection action: a jump inside
  the live intent when the collection is already playing, otherwise a new
  intent (`SURFACE-003`).
- Start Retired playback directly, or continue the same context from iOS.
- Now Playing transport controls, provided by the system and acting on the
  player directly.
- Shuffle and repeat, as the system's own Now Playing controls, reflecting and
  setting MusicKit's modes (`PLAY-004`).
- Retire the current track.
- Promote the current bucket track, whether or not it is retired — deciding to
  keep a track you had set aside is the point of hearing it again.
- Move the current retired track to Triage with explicit keep intent.
- Return to the root menu from Now Playing.

CarPlay does not provide a separate skip-history browser. Now Playing metadata
and artwork come from the `ApplicationMusicPlayer` host. Custom buttons are
enabled only when the current entry is attributed (`PLAY-012`). A shared
playback failure presents one alert per failure episode (`PLAY-014`).

CarPlay UI logic should remain isolated from the iPhone/iPad SwiftUI shell.
The iPad shell does not depend on CarPlay-specific types or entitlements; the
same isolation is required for the planned Mac target.

## Development Guidelines

- Keep MusicKit calls out of SwiftUI view bodies.
- Use async/await for MusicKit and network work.
- Use `@MainActor` for UI-facing observable objects.
- Prefer small SwiftUI views and focused services.
- Preserve history during sync.
- Make all playlist mutation failures explicit and non-fatal.
- Prefer local filtering over blocking the user when Apple Music mutation is
  unavailable.
- Keep device-local playback state out of iCloud-backed records.
- Keep CarPlay templates thin; route playback and queue actions through shared
  services.
- Avoid adding compatibility paths for pre-iOS 26 or pre-iPadOS 26 systems.
- The planned Mac target starts at macOS 26 and should not add older-system
  compatibility paths.
- Prefer shared SwiftUI views that adapt by size class and platform idiom, but
  create platform-specific shells when a native iPad or Mac pattern is clearer.
- Add keyboard shortcuts and menu commands only as roadmap work once the
  underlying action exists.

## Current Product Definition

The product is healthy when a user can:

1. Install and run Overplay on iPhone and iPad.
2. Connect Apple Music on either target.
3. Choose a One True Playlist.
4. Add contributing playlists to the triage bucket.
5. Sync all linked playlists.
6. Play any linked playlist in Overplay.
7. Track skips and playthroughs for all linked playlists.
8. Surface skip/playthrough history while leaving retirement to explicit user actions.
9. Manually retire and restore tracks from any linked playlist.
10. Promote bucket tracks into the One True Playlist.
11. Search Apple Music and add tracks to active managed linked playlists.
12. Share playlist, stats, and retirement data across devices through iCloud.
13. Keep each device's current playback state independent.
14. Use an adaptive iPad split-view layout for navigation and management.
15. Use a CarPlay music player for playlist browsing, Now Playing controls,
    and playback through the shared playback controller.
16. Start a playback action on any supported surface and see the same
    player-reported current track, playlist context, play state, position,
    statistics and history on every other active surface within one
    observation cycle, without manual refresh.
17. Keep playing, and keep knowing what Overplay asked to play, through
    unattributable entries, slow or failing Apple Music calls, sync, CloudKit
    imports and relaunches. Recover from any playback failure with Play, without
    restarting the device.


## Documented music identity and duplicate review (#40)

Library-to-catalog correspondence comes from Apple Music's library song `catalog`
relationship, requested through `MusicDataRequest`. Catalog lookups capture ISRC;
missing catalog resources use Apple's REST `filter[equivalents]`, and ISRC lookups
supply additional candidates. Existing deployment targets remain unchanged.

Identity precedence is contextual: local UUIDs identify durable Overplay rows;
playlist entry IDs identify occurrences only within their playlist. Exact library
IDs anchor catalog changes. Documented catalog relationships and confirmed aliases
identify records across syncs. ISRC and catalog equivalents are review evidence,
not automatic merge keys. Titles/artists never establish identity. Opaque
PlayParameters decoding remains only a fallback for records without documented
identity. A documented empty catalog relationship preserves library-only content.

Lookups run during sync or an explicit scan, never in view rendering or playback
controls. Requests contain at most 25 IDs, with at most three requests in flight
across scan and sync. Catalog metadata included with library songs is reused
instead of fetched again. A bounded memory cache keeps unique
successes for seven days and negative/ambiguous results for one hour. Restart,
account fingerprint changes, or storefront changes invalidate cached results;
request failures are not stored as proof of absence. Tokens are not persisted or
logged. MusicKit authorization and live catalog responses need device validation.

Settings > Find Duplicates scans local recordings and shows apparent duplicate
groups, song and album details, counts and collection membership. Technical
identifiers are used internally and are not displayed in the review screen. Users
select the recordings to merge and confirm. Mixed collections require choosing One True
Playlist, Triage, or Retired; a shared collection is retained. Canceling performs
no merge. ISRC/equivalence can include different versions, so suggestions require
human review.

A confirmed merge revalidates identity and location, records the donor track
UUID in the keeper's `absorbedTrackIDs` so the ledger-derived counts include
the donor's events, retains source attachments/keep intent and latest activity
dates, and repoints history. Confirmed aliases prevent subsequent sync
from recreating donor tracks. One track and one travelling statistics row remain.
The shared playback controller rewrites merged member track UUIDs in the
playback intent and refreshes published state, without manufacturing a skip or
touching the live queue. Destination writes use
the existing Apple Music mutation paths; local OTP suppression remains protective
when remote removal fails or the playlist is incoming-only.

Generation 2 replaces the old record types and does not migrate historical track identities.


## Generated playlist artwork

Artwork settings are presented above the persistent player sheet. Saving,
cancelling, or dismissing settings reveals the mini player without interrupting
playback.

Each playlist saves its own artwork template: Pile (default), 3 × 3 grid, or
8 × 8 grid, with None (default), Black, or White borders. Border width is 1.5%
of the individual cover side length. The square artwork appears above playback
controls in playlist detail, as a thumbnail in the root playlist menu, and beside
that playlist in the CarPlay playlist list. Root playlist-row artwork is 96 × 96
points with square corners and no vertical row insets, filling the row height.
Linked-playlist artwork remains 72 × 72 points, matching track-row artwork.
Long-press offers Settings and Regenerate; Settings saves layout and border choices.

Covers are grouped by artwork URL. Active Overplay/One True Playlist artwork
ranks by summed Overplay playthrough counts across songs sharing a cover.
Triage and other playlists rank by newest addition/movement time; Retired always
ranks by newest retirement time. Equal ranks are randomized during generation.
Grids select the highest-ranked 9 or 64 distinct covers, repeat only to fill
empty cells, and shuffle the cell order. Pile draws from lowest to highest rank,
placing the most-played OTP cover or newest Triage/Retired cover on top, over a
repeating lower-ranked background that fills the canvas and extends past its edges.
This artwork ranking does not change track-list or unshuffled playback order.
Foreground covers have random side lengths of 30–60% of the canvas, rotations of
−3° to +3°, and random positions whose rotated corners stay inside the canvas.
The top cover is always 50%, centred, and slightly rotated. Borderless Pile covers
have a subtle black drop shadow (24% opacity, blur 1.2% of the cover side, downward
offset 0.6%). Grids and covers with black or white borders have no drop shadow.

The arrangement is persisted and the completed 1024 × 1024 image is cached as PNG,
shared by SwiftUI and CarPlay. It stays stable for 24 hours, refreshing on the next
view afterward, on changed settings, or on manual regeneration. Cache eviction
re-renders the saved arrangement. Unavailable artwork does not become a permanent
completed cache entry. Empty playlists show a placeholder and can generate as soon
as artwork arrives. Retired views use only retired tracks, with a separate saved
arrangement and PNG cache from active Triage. Layout, borders, regeneration, and
daily refresh are independent for active Triage and Retired. Each defaults to Pile
with no border; changing either template does not regenerate the other collage.


## Datastore generation 2: configuration-preserving rebuild

Decision (September 2026): replace the pre-release store, preserving only the
active One True Playlist and triage source links, their names, order, and write
permissions. Reimport songs from Apple Music. Discard old tracks, ownership,
retirements, counters, history, collage snapshots and playback restoration.
The cutover must not write to Apple Music. Retain the old store and a verified
configuration export for recovery; do not migrate its track graph.

The new store uses a distinct store name and distinct persistent entity names.
Old CloudKit record types must never be interpreted as generation-2 entities.
CloudKit remains private to the iCloud owner. One dataset represents one Apple
Music library; a library resource identifier is scoped to that dataset, not to a
device or an authorization token. A different Apple Music library requires a new
configuration/rebuild; a missing playlist must fail rather than relink by name.
Old clients cannot contribute generation-2 track or count records.

Schema:

- LibrarySettingsV2: Overplay settings and the completed rebuild receipt.
- LibraryPlaylistV2: Overplay UUID, Apple Music playlist reference, display name,
  role, write permission, link intent and sync bookkeeping. The synthetic Triage
  bucket has no Apple Music resource. Only configured sources survive cutover.
- LibraryTrackV2: Overplay UUID; independently typed catalog and library resource
  references; confirmed aliases carrying their domain and library scope; recording
  metadata. ISRC and equivalent recordings are review evidence, not identity keys.
  Equal strings in different resource domains do not identify the same song.
  When several library resources prove the same catalog identity, retain every
  binding and choose the lexicographically smallest library ID as the stable
  representative for metadata and playback reconstruction. Source arrival order
  must not alternate that representative or rewrite its metadata.
- LibraryMembershipV2: one travelling ownership/statistics row per track, referring
  to playlist and track UUIDs. Current source occurrences remain provenance, not
  additional songs or counters. Overplay wins initial import conflicts; subsequent
  explicit user moves and retirement retain their existing precedence.
- LibraryHistoryV2: events referring to Overplay UUIDs, never native MusicKit IDs.
- LibraryAppleCountV2: append-only count observations and reset/lineage evidence.
  Existing cumulative Apple counts establish fresh baselines, not Overplay plays.
- LibraryListenV2: the append-only listen ledger (`COUNT-002`), added after the
  generation 2 cutover as a purely additive entity.

Native MusicKit objects are rebuildable process-local playback material. They are
not fields in the synced schema and must never supply automatic merge keys.
Playback, UI, CarPlay and sync use the same Overplay UUIDs and shared repositories.
Only HTTP(S) artwork references are portable persisted metadata; native artwork
handles stay outside the shared graph.

Rebuild protocol: validate a configuration-only export; fetch complete song and
identity snapshots for every configured source without changing persistence;
reject unresolved identities, incomplete pages and changed configuration; stage
all records in a context with autosave disabled; assign one membership per proven
identity, prioritising Overplay and retaining all contributing source occurrences;
commit the complete graph and receipt together. A failed fetch publishes no songs.
A completed receipt makes restart idempotent. No old counters or library lifetime
counts are copied as Overplay activity. Normal sync starts only after a pending
rebuild succeeds. A failed rebuild remains retryable and visible as an error.

Validation must cover resource-domain collisions, aliases, native-cache exclusion,
configuration validation, overlapping source playlists, input-order independence,
failure before commit, zero initial activity and restart idempotence. Build and
unit checks precede the authorized live cutover. Verify live roles and counts
against source snapshots, then restart and repeat sync. CloudKit convergence and
CarPlay hardware behavior must be reported separately from local test evidence.


### Generation 2: first launch on another device

A new local V2 store is not evidence of a new user. Startup must not create
settings, a triage bucket, or replacement memberships while iCloud restoration
is pending. The shared runtime owns a restoration gate used by library
browsing, curation, sync, ledger writes, background reconciliation and artwork
maintenance. Playback is not gated: the device-local playback intent can be
restored, shown and played before restoration completes (`PLAY-010`).

On an unrecognised local store, require a successful import event for that
store and a usable configuration: exactly one settings record, its selected
Overplay playlist, a triage bucket, and valid track/playlist references for
all memberships currently delivered. Do not repair incomplete references or
choose arbitrarily between competing settings records. A cloud rebuild receipt
alone does not establish device readiness. CloudKit delivers records
incrementally; this gate establishes configuration and referential readiness,
not an atomic snapshot of every cloud record. Later records can still arrive.

After 30 seconds, show a recoverable waiting screen instead of an indefinite
spinner. Failed imports display their error; Retry rechecks without creating
records, and later successful imports automatically retry while the app is
open. A device-local receipt permits subsequent offline launches of the same
restored configuration. The device that performed the explicit rebuild may
also establish readiness using its saved configuration export matched to the
persisted rebuild UUID. Restoring preferences without the corresponding graph
must not bypass the gate. An explicit database reset creates the new base
configuration and records its local origin so it can reopen offline.

A genuinely new installation may explicitly create a library only after a
successful cloud import has left all V2 entities empty. This action explains
that an existing library should be restored instead and rechecks emptiness
immediately before saving. It is unavailable when a legacy store exists.
There is no automatic legacy graph migration, timeout reset, or fallback to
an empty library on cloud failure. This does not provide distributed locking
between two devices deliberately creating a new library at the same time.

Distribution verification must distinguish Development and Production
CloudKit environments. Deploying a schema does not copy private user records
between them. Verify the appropriate schema and library in the environment
used by the iPhone build before claiming cross-device restoration works.


### Artwork identity and presentation

Library artwork is metadata of the Apple Music library resource; it must be
preserved even when that song has no unique catalog relationship. A catalog
match is not a prerequisite for a cover. Persist only portable artwork URLs;
MusicKit-native artwork handles remain device-local. Missing artwork can be
refreshed separately from playlist contents without resetting identities,
memberships or activity. A library upload with no supplied artwork keeps the
normal placeholder.

The shared now-playing display prefers the actual player-reported track. Once
it matches the reconciled current song, its cover uses the same portable
artwork as stored rows. Player artwork and theme use that shared projection;
an incoming unresolved song must never borrow the outgoing song's artwork.

## History: Abandoned Playback Approaches

This section records approaches that were built, shipped or prototyped and then
withdrawn. **Do not reintroduce any of them without new device evidence and an
explicit spec change that explains why the original failure no longer applies.**
Each entry gives what was tried, why it was attractive, and why it failed.

### H-1. Overplay-owned shuffle, repeat and end-of-queue rebuild (`PLAY-001`, withdrawn 2026-09-07)

Overplay kept its own shuffled order, forced MusicKit's modes off and rebuilt
the queue at the end of the playlist. MusicKit's modes could be changed by any
system surface, and holding them off was a constant fight. A latent bug
(`repeatMode = .none` binding to `Optional.none`) meant repeat was probably
never disabled at all, so most observations of queue-end behaviour from before
2026-09-06 are untrustworthy. MusicKit now owns both modes (`PLAY-004`).

### H-2. Windowed queue hand-off (`PLAY-002`, withdrawn 2026-09-07)

The queue was handed over 50 entries at a time and topped up, to reduce load
suspected of wedging Apple Music. A 69-hour device log showed the Apple Music
stack degrading anyway, with queue replacements capped at 50 and only 385
total calls. A window also cannot be shuffled or repeated by MusicKit. The
complete scope is submitted in one queue (`PLAY-005`).

### H-3. Mirror-playlist engine (parked, never merged)

Playback from an Overplay-owned Apple Music playlist handed over as a `Playlist`
entity, so Apple Music would own shuffle. `Queue(playlist:startingAt:)` needs a
`Playlist.Entry`, so playback could not start at an arbitrary track without
another fetch. Every content change also required an unbounded
`MusicLibrary.edit`. The commit is archived as tag
`archive/apple-music-owned-shuffle`. Issue #17 has the details.

### H-4. Entry-ID queue correlation (replaced 2026-10-04)

Overplay minted `MusicPlayer.Queue.Entry` values, recorded their IDs, and
treated the player's current entry ID as its key to what was playing. MusicKit
does not preserve those IDs: it re-materializes queues at hand-off and after
mode changes. It also reports item IDs from a different identifier domain
than the ones submitted (Apple developer forum thread 727737). To cope,
correlation grew a submitted-manifest, metadata matching, position matching,
a persistent association cache, a runtime alias store, append correlation and
hydration waiting. Whenever all of these failed, Overplay cleared the playlist,
the current track and the restore point, and with them every count and
curation action, while playback carried on. That was the main reason Overplay
"lost track of what is playing", and the cause of issue #26 (counts stopped).
Replaced by the playback intent and attribution (`PLAY-010`, `PLAY-012`),
neither of which can clear state.

### H-5. Player-confirmed transitions (replaced 2026-10-04)

Every command waited up to 2.1 seconds (21 × 100 ms) for the player to confirm
the expected entry. Overlapping commands were rejected with "Another playback
transition is still being confirmed", while remote commands had already
reported success. When confirmation timed out, Overplay automatically
replaced the queue again to restore the previous one, and then wiped its state
if that did not confirm either. Under Apple Music degradation (single calls of
4.6 seconds were logged), this added queue replacements exactly when the service
was struggling, and silently dropped user commands. Commands are now single
calls, and state follows observation (`PLAY-013`).

### H-6. Automatic chronological-order repair (replaced 2026-10-04)

When shuffle was off and the live queue order differed from display order (for
example after sync added tracks), Overplay replaced the whole queue and seeked
back to the current position mid-track. This caused audible glitches, and
probably contributed to issue #58 (a second of track 1 playing). The live queue
is no longer mutated by membership changes (`PLAY-015`).

### H-7. Overplay as a second Now Playing client (replaced 2026-10-04)

Overplay wrote `MPNowPlayingInfoCenter` from its own belief about what was
playing (throttled by `NowPlayingPublishPolicy`). It also registered
`MPRemoteCommandCenter` handlers, which it enabled and disabled from that same
belief: Pause was disabled during a delivery stall, and Next/Previous during
confirmation. `ApplicationMusicPlayer`'s host already publishes Now Playing, so
MediaRemote had two clients to choose between. Commands sometimes ran through
Overplay and sometimes went straight to the player, and system surfaces could
show Overplay's stale belief. Apple Support has said remote-command customisation
is not supported with the application music player (forum thread 688007).
Apple's CarPlay Music sample only observes its player. Removing the
second client was the leading unaddressed suspect from the September Apple
Music failure investigation. See `PLAY-016`, and the iOS 27 CarPlay caveat in
**Known Defects and Verification Gaps**.

### H-8. Live queue append and prune on membership changes (replaced 2026-10-04)

Sync additions were appended to the live queue and later correlated back.
Retirements pruned entries in place. Each mutation needed its own
correlation and retry bookkeeping, and an appended entry that never correlated
read as divergence and tore playback down. Replaced by skip-on-reach and
next-start additions (`PLAY-015`).

### H-9. Automatic delivery-stall recovery (removed 2026-10-04)

A frozen stream triggered `prepareToPlay()` and `play()` automatically, with a
two-attempt budget that refilled after five healthy ticks. Device evidence
exonerated it as a cause of the September failures, but it was still automatic
Apple Music traffic during degradation. Recovery now runs only on a user Play
press (`PLAY-014`).

### H-10. All-or-nothing, memory-only playback preparation (replaced 2026-10-04)

Native `Track` objects were cached in process memory only. Every cold launch
therefore had to resolve every track in the scope before playback could start,
and one unresolvable song failed the whole playlist. The cache is now on disk,
and unresolvable songs are omitted (`PLAY-017`).

### H-11. Mutable synced counters (replaced 2026-10-04)

Skip and playthrough counts were integers on CloudKit-synced rows. They were
incremented in place, summed into a keeper when duplicates merged (the donor
row was then deleted), and zeroed on reset. Under CloudKit, concurrent
increments on two devices are last-writer-wins, and an increment to a donor row
racing a merge is lost. History is pruned, so it cannot rebuild the counts.
Replaced by the listen ledger (`COUNT-002`). Apple play counts already used
append-only observations.

### H-12. Per-minute Apple play-count polling (reduced 2026-10-04)

From 2026-09-25 the bulk refresh queried every retained track every 60 seconds,
plus a full library scan every 15 minutes, including during playback. This was
the largest new source of background MusicKit load added after the September
failure evidence. The cadence is now bounded and paused during playback and
failure (`LOAD-001`).

### H-13. Device-local playback order store (removed 2026-10-04)

A per-player, per-playlist stored order (`PlaybackOrderStore`, reshuffle
engine, merge-on-demotion) outlived `PLAY-001`. Display and queue order come
from SwiftData dates, so the store had no observable effect, but it was still
rewritten, rekeyed and merged by many code paths.

### H-14. Playback gated on iCloud library restoration (changed 2026-10-04)

The whole app, CarPlay included, waited behind "Restoring your library" until
the CloudKit import validated. Remote commands and playback monitoring were not
installed until then. Playback now starts from the device-local intent
independently of restoration.

### Unconfirmed hypotheses (kept for reference)

- MusicKit re-issues queue-entry IDs when shuffle is written to a loaded queue.
  This was never confirmed on device. The current design does not depend on it
  either way.
- Overplay's combination of a second Now Playing client and background library
  traffic wedged the system Apple Music stack, which needed a reboot to recover.
  This is not proven. The 2026-10-04 design removes both, and the September
  activity log (Settings → Apple Music Call Activity) remains the way to check
  any recurrence.

### Testing lesson

On 2026-10-04 all 978 unit tests passed against the H-4 to H-8 design while it
failed on device. The fake player kept entry IDs stable, hydrated items
synchronously and never failed slowly, which made the real failure modes
impossible to observe. The acceptance gate in **Cross-Surface Playback
Consistency** requires a fake that re-issues IDs, crosses identifier domains,
hydrates late and fails. Before trusting a guard's test, delete the guard and
confirm the test fails.
