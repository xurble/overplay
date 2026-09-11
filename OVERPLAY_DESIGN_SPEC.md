# Overplay Current-State Product and Design Specification

## Specification Status

This document is the canonical specification for behaviour implemented in the
repository as of 2026-09-08. Requirements describe the current iPhone, iPad,
and CarPlay product unless a section is explicitly labelled **Planned**.
Future work belongs in `TODO.md`; implementation details are requirements only
when they create observable behaviour or protect a stated invariant.

Evidence priority is executable tests, public UI and persisted models, then
implementation. Known defects and dead paths are recorded separately and are
not product requirements.

## Purpose

Overplay is an Apple Music companion app for iPhone, iPad, and CarPlay.
It keeps a user's main music playlist fresh while using other playlists as
intake and triage sources.

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

## Current-State Requirement Index

| ID | Requirement | Primary evidence |
| --- | --- | --- |
| `PLAT-001` | The current app supports iPhone and iPad on iOS/iPadOS 26+, with CarPlay supplied by the iPhone app. A native Mac target is planned, not implemented. | `Overplay.xcodeproj/project.pbxproj`, `Overplay/App/Shell/PlatformShell.swift` |
| `AUTH-001` | Normal use requires Apple Music authorization, catalogue playback capability, and Sync Library. The simulator supplies a ready state for development. | `Overplay/Services/MusicAuthorizationService.swift`, `Overplay/App/StartupAuthorizationGate.swift` |
| `PLAYLIST-001` | Exactly one active One True Playlist is selected. Selecting another demotes the previous main playlist to a triage source. | `Overplay/Persistence/PlaylistRepository.swift`, `OverplayTests/NewModelRepositoryTests.swift` |
| `PLAYLIST-003` | There is at most one triage bucket. It owns every triage item, is ensured during startup, and has a reserved `musicPlaylistID` rather than an Apple Music playlist, so it is never fetched or synced directly. | `Overplay/Persistence/PlaylistRepository.swift`, `OverplayTests/TriageBucketTests.swift` |
| `PLAYLIST-004` | Sources contribute attachments, not duplicate rows. A deliberate source link/re-link revives older retirements into Triage; ordinary sync never revives them. Active OTP takes precedence over source intake. | `Overplay/Services/TrackLocationService.swift`, `OverplayTests/GlobalTrackOwnershipTests.swift` |
| `PLAYLIST-005` | Last-source unlink deletes untouched, non-explicit active Triage rows and unowned retired 0/0 rows. Active explicit keep or prior listening (even reset) survives. Nonzero counts and necessary OTP suppression always survive. | `Overplay/Persistence/TrackRetentionPolicy.swift`, `OverplayTests/GlobalTrackOwnershipTests.swift` |
| `PLAYLIST-007` | One item per track app-wide owns its statistics. OTP, Triage and global Retired are three top-level collections; every retired item belongs to the bucket. | `Overplay/Persistence/PlaylistItemRepository.swift`, `Overplay/Services/TrackLocationService.swift` |
| `PLAYLIST-006` | Pre-bucket triage data migrates onto the bucket at startup, merging counts for tracks that appeared in several triage playlists. The migration is idempotent and keyed on the stored legacy role value, not a local flag. | `Overplay/Persistence/TriageBucketMigrationService.swift`, `OverplayTests/TriageBucketTests.swift` |
| `PLAYLIST-002` | Initial setup can create a managed playlist, copy an existing playlist into a managed playlist, or link an existing playlist as incoming-only. | `Overplay/ViewModels/PlaylistSelectionViewModel.swift`, `Overplay/Services/PlaylistSyncService.swift` |
| `SYNC-001` | Automatic sync starts shortly after authorization, runs every 30 minutes, skips fresh successful playlists, retries failed playlists, and prioritizes the playing and selected playlists. | `Overplay/Services/PeriodicPlaylistSyncService.swift`, `OverplayTests/PeriodicPlaylistSyncServiceTests.swift` |
| `SYNC-002` | Sync is idempotent, collapses duplicate identities, preserves history, and leaves remotely missing tracks locally playable unless retired. | `Overplay/Services/PlaylistSyncService.swift`, `OverplayTests/PlaylistSyncReconciliationTests.swift` |
| `MUT-001` | Successful promotion moves the existing item into OTP with its statistics and history; no source copy remains. Retired offers Move to Triage (explicit keep) and Move to One True Playlist. | `Overplay/Services/PlaylistMutationService.swift`, `OverplayTests/PlaylistMutationServiceTests.swift` |
| `MUT-002` | Apple Music search can add songs only to active playlists that allow remote writes. | `Overplay/ViewModels/SearchMusicViewModel.swift`, `OverplayTests/SearchMusicViewModelTests.swift` |
| `RETIRE-001` | Retirement is authoritative locally and globally equivalent from OTP/Triage. Managed OTP retirement attempts remote removal from rows and Now Playing; incoming-only OTP and Triage retirement stay local. Stale OTP membership cannot revive or silently re-promote the row. | `Overplay/Services/PlaybackController.swift`, `Overplay/Services/TrackLocationService.swift` |
| `PLAY-001` | **WITHDRAWN.** Overplay owned queue order, shuffle and repeat. Replaced by `PLAY-004`; no longer implemented. | — |
| `PLAY-002` | **WITHDRAWN.** The queue was handed over a window at a time. A window cannot be shuffled or repeated by MusicKit, so it could not coexist with `PLAY-004`; device evidence also showed hand-off size was not the cause of the Apple Music failures it was built for. | — |
| `PLAY-004` | MusicKit owns shuffle and repeat. Overplay reads both modes, writes what a surface asked for, and never reorders or rebuilds the queue to emulate them. | `Overplay/Services/PlaybackController.swift`, `Overplay/Playback/PlaybackPlayer.swift` |
| `PLAY-005` | Overplay hands MusicKit the complete playback order for the selected scope in one queue, because MusicKit can only shuffle or repeat what it holds. | `Overplay/Services/PlaybackController.swift` |
| `CAR-001` | CarPlay is playlists, then the tracks in one, then Now Playing. Every playback and curation action a driver needs is on Now Playing. | `Overplay/CarPlaySupport/CarPlayCoordinator.swift`, `Overplay/CarPlaySupport/CarPlayNowPlayingActionPolicy.swift` |
| `TRACK-001` | Skips require witnessed listening and are never reconstructed from stale or suspended spans. Playthroughs are position-based and can be recovered only from explicit proof. | `Overplay/UseCases/PlaybackSessionEvaluationService.swift`, `Overplay/Services/PlaybackReconciliationService.swift` |
| `HISTORY-001` | History is filterable and paged. Ignored-skip events expire after 30 days and other events after 365 days, with bounded cleanup. | `Overplay/Views/HistoryView.swift`, `Overplay/Services/HistoryRetentionService.swift` |
| `SETTINGS-001` | Current settings cover tracking thresholds, statistics reset, shared database reset, playlist selection, and MusicKit diagnostics. | `Overplay/Views/SettingsView.swift`, `Overplay/ViewModels/SettingsViewModel.swift` |
| `SURFACE-001` | Every playback action exposed by SwiftUI, CarPlay, Lock Screen, Control Center, or a headset/media transport has identical semantics and runs through the shared playback controller. A surface may expose fewer actions, but it must not implement a different version of an action. | Confirmed product requirement (2026-08-31); `Overplay/Services/RemoteCommandService.swift`, `Overplay/CarPlaySupport/CarPlayCoordinator.swift` |
| `SURFACE-002` | A playback action or player-observed transition on any surface must reconcile and publish one authoritative playback snapshot to every other surface. Current-track identity, queue context, play state, position, outgoing-track evaluation, active-playlist projection, restore state, and system now-playing metadata must not diverge. | Confirmed product requirement (2026-08-31); `Overplay/Services/PlaybackController.swift`, `Overplay/Services/NowPlayingMetadataService.swift` |

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
- Device-local state: `AppStorage` for playback and navigation state that
  should not sync between devices.
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
- Support lock-screen metadata, remote commands, and the CarPlay music player.

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
This also runs immediately on retirement and ordinary counter reset. Nonzero
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
- Skip count.
- Playthrough count.
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

Apple Music exposes two identifier domains for the same song: catalog IDs and
library IDs (prefixed with `i.`). Overplay stores them in separate fields and
never mirrors one into the other. When MusicKit exposes a library track's
catalog correspondence through its play parameters, sync captures it so the
two domains link and the same song fetched from search, sync, or the playback
queue resolves to one local track record.

Identifier fields are fill-and-heal only: an update may add a missing
identifier or replace a wrongly-domained legacy value, but a source that sees
only one domain must never erase the other.

Duplicate track records describing the same song (legacy mirrored IDs, or
CloudKit insert races, which cannot enforce unique constraints) are collapsed
by an identity merge pass that runs at startup and after each sync. The
oldest record wins; playlist items and history events repoint to it. When two
items for the same playlist collapse, skip and playthrough counts are summed
and retirement state follows the most recently updated item — merge must never
discard counts. Device-local order, alias, and playback-state
stores rekey their local track IDs in the same pass.

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

Artwork loading must not block playlist rendering or playback. Playlist and
track lists show placeholders immediately, then load cached or downloaded art in
the background. When playback needs current-track artwork that is not cached,
the player requests it at high priority and caches the result without delaying
queue setup, playback, or skip/playthrough evaluation.

The cache has a default 250 MB budget. When it exceeds that budget, eviction
starts with artwork associated only with least-recently-used playlists, then
least-recently-accessed files within those groups. Artwork associated with the
currently playing playlist is preserved during the artwork cache eviction pass.

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

Local retirement is authoritative. When the user retires the currently playing
track, Overplay also attempts Apple Music deletion only when the source is a
managed One True Playlist. Retiring a playlist row, retiring from the triage
playlist, or retiring from an incoming-only playlist is local-only. A failed or
unsupported remote deletion never rolls back the local retirement.

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

- Attempt to add the track to the linked Apple Music One True Playlist.
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

Overplay records global per-track playthrough and skip counts. Promotion from
triage and retirement from any playlist are manual user actions. Skip counts
are displayed as history only; they do not imply an automatic status, and
retirement remains an explicit user action.

### Defaults

```swift
skipThresholdPercentage = 50
minimumSkipListeningSeconds = 10
playthroughThresholdPercentage = 90
```

### Skip decision

A skip is counted when all are true:

- The current play session has not already been evaluated.
- The tracked item exists; Retired auditions count on the same path.
- The user listened for at least `minimumSkipListeningSeconds`, measured as
  witnessed listening time accumulated from playback observation, not as raw
  playback position. Seeking or resuming mid-track contributes nothing.
- Playback progress is less than `skipThresholdPercentage`.
- The transition was not a natural completion — either reported explicitly or
  inferred because the last observed position was within a few seconds of the
  track duration.
- The playback observation is fresh. Playback continues out-of-process while
  Overplay is suspended, so a transition judged from a stale observation
  counts nothing: an unobserved interval must never produce a skip. A
  playthrough threshold that was genuinely observed before the observation
  went stale still counts as a playthrough.

Manual Next should evaluate the outgoing track. Previous should generally not
count as a skip. Starting a different playlist or track evaluates the
outgoing track by the same rules. Sessions restored for display after a
relaunch are never evaluated.

If the user skips after the skip threshold but before the playthrough
threshold, neither the skip count nor the playthrough count changes.

### Playthrough decision

A playthrough is counted when the track reaches
`playthroughThresholdPercentage` or natural completion is detected.

Playthrough evaluation is position-based rather than witnessed-time-based.
Seeking to or beyond the threshold can therefore count a playthrough; this is
an intentional current product rule. Seeking does not contribute to the
witnessed listening time required for a skip.

Playthroughs and skips accumulate independently. A playthrough does not reset
the playlist item's skip count.

### Suspended-playback reconciliation

Playback continues out-of-process while Overplay is suspended, so the live
monitor cannot witness it. Skips are NEVER reconstructed for suspended
spans — an unobserved interval must never produce a skip. Playthroughs are
recovered retroactively on any wake (a background refresh grant, scene
foregrounding, or entering the background, which records the exact baseline
waypoint) under three proof rules; anything ambiguous counts nothing:

- Point-proof: an observation showing the current track at or past
  `playthroughThresholdPercentage` counts the playthrough outright.
  Playthroughs are position-based, so a single trusted position observation
  is sufficient proof.
- Continuity-proof: between two waypoints, if elapsed wall time accounts for
  the durations of every traversed track in the stored playback order
  (small per-boundary tolerance), each completed track counts. Any pause,
  skip, stall, unknown duration, or playlist change fails the equation and
  nothing in that span is counted.
- Music-library-proof: a batched `MusicLibraryRequest<Track>` shows that the
  same library item's `playCount` increased and its `lastPlayedDate` advanced
  into the observed interval. Missing, disabled, stale, mismatched, or failed
  MusicKit data is neutral. Unresolved baselines are retained briefly so a
  later wake can observe delayed counter propagation.

Reconciled events are logged with the `reconciled` history source and their
proof mechanism (`pointObservation`, `wallClockContinuity`, or
`musicKitPlayCount`). History presents all-time and recent recovered-write
totals, a mechanism breakdown, a recovered-playback filter, and the proof on
each event. Events written by older builds are classified from their existing
message where possible. Background wakes
are aimed at the playthrough-threshold crossing of the current track — the
earliest instant a single snapshot is self-sufficient proof; iOS delivers
refresh grants late and allows one pending request, so aiming at the start
of the proof window maximises retention and a late grant still pins the
track boundary for continuity. Double counting is prevented by the live
session's evaluated flag, a counted-track ledger on the waypoint, and the
item's `lastPlayedAt` recency.

Background entry flushes a local waypoint before awaiting library metadata.
If that request is cancelled or never completes, local proof remains available;
new library baselines are only available after a successful response. Background
refreshes submit a replacement before awaiting reconciliation, with a 15-minute
fallback when no track target is available. iOS can reject requests or withhold
grants, so recovery does not assume per-track wakes.

At background entry, one batch also samples up to 20 following tracks in the
stored order. At most 41 unresolved baselines (two windows plus the current
track) are retained for 24 hours, with original timestamps preserved across
wakes. A qualifying counter advance credits at most one playthrough even if
its delta exceeds one: only the final play has a dated observation. Expired or
ambiguous evidence credits nothing. While MusicKit shuffle is enabled, stored
order is only a candidate-selection heuristic, not proof of traversal;
wall-clock continuity is disabled. Recovery then covers sampled tracks whose
library metadata proves a play, plus the current track's position proof.
Long unattended spans beyond the sampled window, delayed or unavailable metadata,
and repeated plays can therefore under-count by design.

Stale transitions emit diagnostics but no outcome history event. A later proven
playthrough is the sole history outcome for that unwitnessed transition.

The unused `remote-notification` background mode is removed; `fetch` remains.
The existing `audio` declaration is retained pending physical-device verification
of MusicKit/CarPlay behavior. Its necessity has not yet been established.

### Manual retirement

The user can manually retire a track from any linked playlist. Manual
retirement:

- Moves the same item to the global Retired collection, or deletes it under
  the unowned 0/0 rule above.
- Records a manual retirement event. The current data model may store this as
  an eviction event while Retired remains the user-facing term.
- If retiring from a managed One True Playlist, attempts Apple Music removal.
  The current-track Retire command also advances playback.
- Otherwise keeps the retirement local-only.
- Falls back to local filtering if an attempted remote removal fails.

Retired offers Move to Triage and Move to One True Playlist. Each moves the
existing row to the bottom of the destination order without resetting counts.
Move to Triage establishes explicit keep intent. The separate global Reset All
Stats command retains its existing counter/retirement reset behavior; ordinary
resets preserve prior-activity evidence for active retention.

## Shared vs Device-Local State

The SwiftData store is backed by iCloud so devices on the same account can
share:

- Linked playlist definitions.
- Track metadata snapshots.
- Playlist membership and retirement state.
- Skip and playthrough counts.
- Retirement history.
- Promotion history.
- User-configurable playback-evaluation thresholds.

The following must remain device-local in `AppStorage` or equivalent local
storage:

- Currently playing track/session.
- Current playback queue.
- Current local playback order for each player, playlist, and Active/Retired
  scope.
- Current playback position.
- Current selected screen or playlist view.
- Now Playing UI state.
- Active playlist row projection for the currently playing playlist.
- Any transient sync or playback progress state.

Window-specific navigation and presentation state should use `SceneStorage` or
other scene-local storage when a platform supports multiple windows. The
regular-width sidebar selection currently uses `SceneStorage`; future
multiwindow iPad and Mac work must keep window navigation independent.

Two devices should be able to share playlist and retirement data without
interfering with each other's playback.

## Playback Order, Shuffle, and Repeat

Overplay owns the local playlist order used for display and initial queue
hand-off. SwiftData tracks playlist membership, track metadata, play/skip
history, and retirement state; it does not store that local order or Apple
Music's live shuffled sequence. Local order is disposable and keyed by player,
Apple Music playlist, and playlist scope. Each linked playlist has separate
**Active** and **Retired** local orders. There is no separate unshuffled order
to restore during playback.

> **Direction change (2026-09-07): shuffle and repeat belong to MusicKit.**
>
> Overplay no longer owns shuffle, repeat or the end-of-playlist rebuild.
> MusicKit is authoritative for both modes: Overplay reads them, writes what a
> surface asked for, and leaves the wrap to the player. `PLAY-001` is
> withdrawn.
>
> `PLAY-002`, the windowed hand-off, is withdrawn with it. A window cannot be
> shuffled or repeated by MusicKit, and 69 hours of device evidence showed the
> Apple Music failures it was built to prevent happening anyway, with capped
> queues and 385 total calls. It cost complexity without buying protection.

MusicKit receives the complete playback order for the selected scope in one
queue, because it can only shuffle or repeat what it holds. Overplay owns
queue *contents* — which tracks, filtered by local retirement — and MusicKit
owns the order they play in. This keeps skip tracking,
retirement filtering, playlist display order, CarPlay, system controls, and
remote commands aligned to the same source of truth.

During playback, the shared playback controller should maintain an active
playlist projection for the currently playing playlist. It should contain
stable playlist item IDs, local track IDs, display metadata, artwork source,
skip and playthrough counts, retired/playable state, and current-row
state. Playlist views use this projection only when it matches the displayed
current playlist and selected Active/Retired scope; otherwise they fall back to
SwiftData records ordered by the selected scope's local order state.

Local order state:

- Store only the ordered local track IDs and an update date.
- Seed missing local order from the current unique membership for the selected
  scope. Active order contains active playable items. Retired order contains
  retired items.
- Treat old sort-order, shuffle-mode, and repeat-mode state as disposable.
- Playlist display order should mirror the current local playback order for
  that player, playlist, and scope. The UI should reconcile and persist missing
  IDs into that scope order instead of showing raw SwiftData query order.
- A playlist must not contain duplicate songs. Sync, manual add, and promotion
  should reuse or reactivate the existing playlist item for a song instead of
  creating a duplicate.

Starting playback:

- Starting a playlist sends the complete local order for the selected scope to
  MusicKit in one queue (`PLAY-005`), because MusicKit can only shuffle or
  repeat what it holds.
- If the user starts at a specific track, MusicKit starts at that track within
  the full queue, so the tracks before it remain available to Previous.
- If no track is requested, playback starts at the first track in local order.
- MusicKit and Overplay UI should be reconciled immediately after queue setup so
  every surface agrees on the current track and queue position.
- After queue setup succeeds, the playback controller materializes or refreshes
  the active playlist projection from the same SwiftData records and local
  order used to build the queue.

Shuffle and repeat behavior:

- MusicKit owns both. Overplay reads `shuffleMode` and `repeatMode` and writes
  what a surface asked for; it never forces them to a value of its own.
- Shuffle is a persistent mode, toggled. Turning it on does not reorder the
  local order, replace the queue, or restart playback — MusicKit shuffles the
  queue it already holds, and the current track keeps playing.
- Overplay's repeat control toggles repeat-all on and off. Repeat-one set by
  another system surface remains authoritative and is reflected as not-all.
- There is no end-of-playlist rebuild. When the queue is exhausted Overplay
  credits the track that just finished and stops; whether anything plays next
  is MusicKit's decision.
- A shuffle or repeat change from any surface — Lock Screen, Control Center,
  CarPlay, Siri, the app — is authoritative, and every other surface reflects
  it because they all read the same player state.
- Local order remains the playlist's display order and the order handed to
  MusicKit. It is no longer a playback *sequence* once shuffle is on, so the
  upcoming order is not knowable and no surface claims otherwise.

Additions, retirements, and restores:

- Playlist additions from MusicKit sync, SwiftData sync, manual add, or
  promotion append to the end of the current Active local order.
- If the changed playlist is currently playing, playable additions are
  appended to the live MusicKit queue without restarting playback. The player
  creates those entries, so they are correlated back to local rows on Apple
  Music item ID and retried until they resolve — an appended entry that never
  correlates would read as queue divergence.
- If the changed playlist is currently playing, refresh the active playlist
  projection immediately after the durable SwiftData/local-order mutation so
  visible rows do not wait for SwiftData query invalidation.
- Retiring a track removes it from Active order and appends it to the bottom of
  Retired order.
- Restoring a track removes it from Retired order and appends it to the bottom
  of Active order.
- Membership changes prune no-longer-eligible native queue entries in place,
  preserving MusicKit shuffle/repeat and position. The current entry remains
  until transport advances. Current-track movement settles its outgoing session
  without fabricating a skip; source-unlink cleanup defers deletion while a
  countable session is in flight, then reevaluates retention after accounting.
- When switching away from a playlist, reconcile its local order so already
  retired or otherwise unplayable tracks are removed from Active order before
  it is played again.

All playback surfaces must use the same behavior: Now Playing, mini player,
lock-screen and remote commands, CarPlay, keyboard/media keys, and playlist row
play actions should route through the shared playback controller rather than
implementing shuffle, repeat, queue ordering, or current-track reconciliation
locally.

Active playlist projection updates:

- Track changes update current-row state immediately.
- Skip increments, playthrough counts, manual resets, retirements, restores,
  promotions, queue changes, and local-order changes refresh the projection
  after their shared controller or use-case mutation succeeds.
- When playback switches to another playlist or clears, discard the old
  projection. The old playlist then renders from SwiftData again.
- If projection refresh fails, keep playback and durable SwiftData state
  authoritative and allow the playlist UI to fall back to SwiftData rows.

## Cross-Surface Playback Consistency

Cross-surface consistency is a release-blocking product invariant, not merely
an architectural preference. Playback is one shared engine presented through
many surfaces. iPhone, iPad, CarPlay, Lock Screen, Control Center,
AirPods/headset controls, MusicKit queue state, and system now-playing metadata
must agree about the current track, queue, play state, playback position, and
the result of any track-changing action.

Surfaces do not have to expose identical control sets because platform
affordances differ. However, every action a surface does expose—play, pause,
next, previous, seek, shuffle, repeat, queue replacement, retirement, restore,
or promotion—must execute the same shared behavior as that action on every
other surface. No surface may maintain a private implementation or shadow
playback state.

Track changes can be generated by Overplay controls, CarPlay controls, remote
commands, keyboard or headset transport controls, MusicKit queue advancement,
natural end-of-queue completion, explicit queue rebuilds, playlist mutation,
sync, and playback state restoration. All generated actions should enter the
shared playback controller. All observed external changes should flow back
through the same reconciliation path that updates:

- Observable playback state used by SwiftUI and CarPlay.
- Local active queue identity and current playlist context.
- Skip/playthrough session evaluation for the outgoing track.
- Current-track metadata and artwork.
- `MPNowPlayingInfoCenter` metadata and remote command state.
- Local playback state used for restore.

### State convergence contract

Each controller-initiated action must publish a reconciled shared playback
snapshot immediately after the player confirms the change and before the
initiating surface presents the action as settled. A player-originated or
externally generated change must publish that snapshot no later than the next
active player observation and reconciliation cycle.

Convergence must not depend on background playlist sync, an eventual SwiftData
query refresh, view recreation, CarPlay template-stack replacement, or a manual
refresh. SwiftUI and CarPlay presentation state, the active-playlist
projection, local restore state, and `MPNowPlayingInfoCenter` must be updated
from the same reconciliation result.

Track transitions are ordered operations:

1. Read the actual player-reported outgoing and incoming items.
2. Evaluate and persist the outgoing listening session exactly once.
3. Reconcile the queue identity and current playlist context.
4. Publish the incoming current track, play state, position, statistics,
   history, retirement state, and active-playlist projection.
5. Publish matching system now-playing metadata and remote-command state.

If an engine command fails, no surface may continue to display an optimistic
result as authoritative. The controller must reconcile from the player and all
surfaces must converge on that same confirmed state; surfaces that can present
an error should do so without inventing a different playback state.

### Track-skip parity

A Next action has the same meaning regardless of whether it originates in the
app, CarPlay, Lock Screen, Control Center, a keyboard/media key, or a headset:

- The same thresholds and witnessed-listening evidence decide whether the
  outgoing track counts as a skip.
- The outgoing track is evaluated once, even if multiple surfaces observe the
  transition.
- Every active surface changes to the same player-confirmed incoming track.
- Playlist rows, history, statistics, queue position, restore state, artwork,
  and system now-playing metadata reflect the same result.
- No surface requires navigation, relaunch, template reset, or manual refresh
  to observe the change.

The same parity rule applies to every other shared playback action. Rapid or
overlapping commands may be serialized or rejected, but they must not create
duplicate history, attribute an event to the wrong track, or leave surfaces on
different tracks.

### Acceptance gate

For each supported action, validation must originate the action separately
from SwiftUI, CarPlay, and `MPRemoteCommandCenter` (covering Lock Screen,
Control Center, headset, and media-key transports), plus exercise natural
MusicKit track advancement. Each case must verify:

- The action enters the shared controller or the external transition enters
  the shared reconciliation path.
- The outgoing session is evaluated at most once and against the correct
  track.
- The shared current-track identity, queue context, play state, and position
  match the player-confirmed state.
- SwiftUI, the currently visible CarPlay template, system now-playing metadata,
  remote-command state, and local restore state converge within the timing
  contract above.
- Statistics, history, retirement state, and the active-playlist projection
  reflect the same completed mutation without waiting for periodic sync.

Any stale or contradictory surface is a product defect and a release blocker,
even when playback audio itself continues correctly.

The actual player-reported current item is authoritative when it is available.
Local queue order and cached active-queue entries may help correlate playlist
items and track state, but they must not hide a concrete MusicKit current-entry
change from another surface. If MusicKit reports a new current item that cannot
be correlated to local queue identity, Overplay should still update the visible
now-playing display from that player item rather than continuing to show a stale
local queue entry.

When playback leaves a track, the outgoing session should be evaluated before
shared current-track state is replaced with the incoming track. This keeps skip,
playthrough, retirement, and track updates attached to the track that actually
finished or was skipped, regardless of whether the transition started from the
app, CarPlay, a remote command, or MusicKit itself.

Playback UI should observe shared playback state rather than infer state from a
surface-local action. CarPlay templates, SwiftUI views, system metadata, and
remote commands should be thin adapters over the shared controller and
presentation models.

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
- Active tracks ordered by the device-local Active playback order.
- Retired tracks ordered by the device-local Retired playback order and
  playable as a playlist context from iOS.
- Skip and playthrough counts.
- Retirement state.
- Promote action for triage bucket tracks.
- Manual retire/remove action for active tracks.
- Move to Triage and Move to One True Playlist for retired tracks.
- Search/add action scoped to that playlist.

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

The standard media controls should call into a shared playback controller.

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
- Tracks in their current local order, and nothing else in the list.
- Global Retired as its own root destination, playable directly from CarPlay.
- Current track title, artist, album, and artwork where CarPlay templates
  support it.
- Play, pause, next, previous, and Now Playing controls.
- Direct Retire button in Now Playing for active tracks.
- Direct Move to Triage button in Now Playing for retired tracks.
- Direct Promote button when the current track belongs to the triage bucket.
- An Up Next button that returns to the root menu.

Selecting a track never restarts the track that is already playing. When its
playlist is already the live queue, selection skips to that track inside the
existing queue so the order after it survives; otherwise it builds a fresh
queue starting from that track. The root menu offers no manual refresh: every
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
  its history preserved (see "Removals from Apple Music") — Overplay does
  not model Apple Music deletions as a local removal state.
- Stamp `lastSeenInPlaylistAt` on every sighting (refreshed at most daily
  for unchanged items) so future missing-from-remote logic has accurate
  data.
- Preserve history.
- Publish sync status.

### PlaybackController

- Own Apple Music playback.
- Build full app-owned MusicKit queues from the current local playlist order.
- Own local playback order as the playlist's display order and the order
  handed to MusicKit. Shuffle, repeat and the playlist wrap belong to MusicKit.
- Track play sessions.
- Publish current playback state.
- Forward transitions to shared playback evaluation and track action services.
- Keep playback/session state device-local.
- Isolate future platform-specific playback or media-session differences
  behind a small adapter if APIs diverge.

### TrackActionService / EvictionEngine

- Apply skip and playthrough rules.
- Increment counts and support whole-database statistic reset.
- Manually retire or restore items from any linked playlist.
- Record retirement events. The current implementation may still use eviction
  naming internally.

### PlaylistMutationService

- Add tracks to managed linked Apple Music playlists.
- Promote tracks from the triage bucket to a managed One True Playlist and
  move the same global item on success without retaining a source copy.
- Return explicit success/failure results.

### SearchService

- Search Apple Music catalogue.
- Return lightweight result models.
- Support manual add to active managed linked playlists.

### NowPlayingMetadataService

- Publish current metadata to `MPNowPlayingInfoCenter`.
- Keep lock-screen and remote metadata in sync with playback state.

### RemoteCommandService

- Register remote command handlers.
- Forward play, pause, next, previous, shuffle, and repeat actions to the
  playback controller.
- Avoid retain cycles and clean up handlers when appropriate.
- Support lock-screen, Control Center, and headset transport commands.

### PlatformShell

- Provide the root navigation appropriate to each target.
- Share the same view models and services.
- Own platform-specific menu commands, keyboard shortcuts, toolbar placement,
  window commands, and scene setup.
- Keep platform branching out of business logic.

## Persisted Data Model

The current SwiftData schema retains these concepts. Pre-release schema changes
may use a development reset under the repository data policy.

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
- `musicKitPlaybackData: Data?`
- `createdAt: Date`
- `updatedAt: Date`

Artwork image bytes are intentionally excluded from SwiftData models and
CloudKit sync.

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
- `sortOrder: Int` (legacy persisted value; local playback order is authoritative)
- `skipCount: Int`
- `playthroughCount: Int`
- `lastPlayedAt: Date?`
- `lastSkippedAt: Date?`
- `lastSeenInPlaylistAt: Date?`
- `evictedAt: Date?` (local retirement timestamp in current code)
- `evictionReason: EvictionReason?` (retirement reason in current code)
- `evictionSource: EvictionSource?` (retirement source in current code)
- `createdAt: Date`
- `updatedAt: Date`

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

## Explicit Non-Goals and Deferred Work

The following are not requirements of the current product:

- Native Mac target, Mac windows, menus, tables, and media-key integration.
- Siri, App Intents/Shortcuts, widgets, Dynamic Island, or separate watch
  surfaces.
- Rich dashboard summaries such as recent promotions, unreviewed queues, or
  high-skip queues.
- A separate reset-local-playback-state control or a direct deep link to
  system Settings after authorization denial.
- CarPlay skip-history-only browsing.
- Explicit Now Playing artwork publication through `MPNowPlayingInfoCenter`.
- User-facing keep/protection behavior, and the automatic eviction it
  existed to guard against. Eviction is a manual decision. Persisted
  controller APIs are obsolete implementation debt and must not be treated as
  product behavior.

## Known Defects and Verification Gaps

- The initial physical-device cross-surface acceptance pass was completed on
  2026-09-08. Cross-surface convergence remains a standing release gate: rerun
  the affected checks after every playback, queue, CarPlay, remote-command,
  reconciliation, or Now Playing change.
- CarPlay currently has two open playback-surface reports: custom Promote,
  Retire, and Restore controls are absent on hardware
  ([GitHub #22](https://github.com/xurble/overplay/issues/22)), and the shuffle
  button visibly toggles several times after a track change
  ([GitHub #28](https://github.com/xurble/overplay/issues/28)). Whether the latter
  is presentation-only or reflects real MusicKit mode changes is unknown.
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

The app architecture should keep playback, now-playing metadata, and remote
commands independent of SwiftUI views so CarPlay templates use the same shared
services as the phone UI.

Navigation is three levels and nothing more (`CAR-001`): the root lists the
One True Playlist, Triage and Retired, a collection lists its
tracks, and a track opens Now Playing. There are no shuffle rows and no
one-tap play row — a driver should not have to read a menu to tell two
similar entries apart.

CarPlay supports:

- Browse the One True Playlist, Triage and global Retired.
- Browse playlist tracks with playthrough and skip totals in row detail.
- Select a track to play it, skipping inside the live queue when the playlist
  is already playing so the order after it survives.
- Start Retired playback directly, or continue the same context from iOS.
- Now Playing transport controls, provided by the system.
- Shuffle and repeat, as the system's own Now Playing controls, reflecting and
  setting MusicKit's modes (`PLAY-004`).
- Retire the current track.
- Promote the current bucket track, whether or not it is retired — deciding to
  keep a track you had set aside is the point of hearing it again.
- Move the current retired track to Triage with explicit keep intent.
- Return to the root menu from Now Playing.

CarPlay does not provide a separate skip-history browser. The app publishes
title, artist, album, duration, elapsed time, and playback rate to system Now
Playing metadata; explicit artwork publication remains deferred.

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
    player-confirmed current track, queue context, play state, position,
    statistics, history, and now-playing metadata on every other active surface
    within the cross-surface timing contract, without manual refresh.
