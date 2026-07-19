# Overplay Design Specification

## Purpose

Overplay is an Apple Music companion app for iPhone, iPad, Mac, and CarPlay.
It keeps a user's main music playlist fresh while using other playlists as
intake and triage sources.

The core playlist is the user's **One True Playlist**. Overplay plays it,
tracks the user's own skip and playthrough behaviour, and exposes manual
retirement. Additional linked playlists are tracked as triage playlists. They
can represent sources such as TikTok saves, Shazam discoveries, a friend's
playlist, or any other Apple Music playlist the user wants to review before
promoting songs into the One True Playlist.

Overplay maintains its own history and state. It does not rely on Apple
Music's global play count or skip count.

## Platform

- Target platforms:
  - iPhone on iOS 26 and later.
  - CarPlay through the iPhone app on iOS 26 and later.
  - iPad on iPadOS 26 and later.
  - Mac on macOS 26 and later.
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

Overplay should use one shared SwiftUI app architecture across iPhone, iPad,
and Mac. Product rules, sync, persistence, search, playlist mutation, playback
tracking, and retirement logic should live in shared services and models.
Platform-specific code should be limited to presentation shell, scene
configuration, keyboard/menu commands, entitlement differences, and media
integration differences.

### iPhone

iPhone is the focused playback and quick-triage experience.

- Use compact navigation with a dashboard-first flow.
- Keep Now Playing as the strongest visual surface.
- Prioritize fast actions: play, skip, keep, retire, promote, sync.
- Support lock-screen metadata, remote commands, and the CarPlay music player.

### iPad

iPad is the review and management experience as well as a playback device.

- Prefer `NavigationSplitView` or equivalent adaptive split navigation.
- Use a sidebar for Dashboard, One True Playlist, triage playlists, Search,
  History, and Settings.
- Let playlist detail and Now Playing coexist comfortably on wide screens.
- Support Stage Manager, Split View, Slide Over, hardware keyboard shortcuts,
  pointer hover states, and drag-friendly large touch targets.
- Avoid phone-sized layouts stretched across the full display.

### Mac

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

- All three targets must read and write the same iCloud-backed Overplay data.
- All three targets must keep transient playback and selection state local to
  the device.
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

- **Triage playlists**: additional playlists used as intake sources. Overplay
  tracks skips and playthroughs for these playlists. Tracks can be manually
  promoted to the One True Playlist or manually retired from triage playback.

Each linked playlist stores:

- Apple Music playlist identifier.
- Display name.
- Role: `oneTruePlaylist` or `triage`.
- Write policy: `managed` or `incomingOnly`.
- Last successful sync date.
- Last sync error, if any.
- Whether the playlist is active.

Exactly one active playlist has the `oneTruePlaylist` role. The user may add,
remove, deactivate, or rename linked triage playlists.

### Track state

Overplay tracks each song it sees in a linked playlist. Stats must be stored
per playlist membership so the same song can have different context in the One
True Playlist and in a triage playlist.

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
- Created and updated dates.

When a single catalogue song appears in multiple linked playlists, Overplay may
share metadata, but playlist membership, skip count, playthrough count, and
retirement state must remain playlist-specific.

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
and retirement/protection state follows the most recently updated item — merge
must never discard counts. Device-local order, alias, and playback-state
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
currently playing playlist is protected during the active eviction pass.

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

If Apple Music playlist mutation is available and reliable, Overplay should
also attempt to remove the item from the linked Apple Music playlist. If the
remote deletion fails or is unsupported, local retirement remains authoritative
inside Overplay and the track is filtered out of Active playback.

### Periodic sync

The app should sync:

- On first launch after Apple Music authorization.
- When the user adds or changes a linked playlist.
- When the user manually taps sync.
- Opportunistically on app foreground if the last sync is stale.
- After a successful manual add or promotion.

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

### Promotion from triage playlists

Tracks in triage playlists can be manually promoted to the One True Playlist.
Promotion should:

- Attempt to add the track to the linked Apple Music One True Playlist.
- Create or reactivate the local One True Playlist item on success.
- Preserve source triage stats and history.
- Record a promotion event linking source playlist and destination playlist.
- Leave the source triage playlist unchanged unless a future setting says
  otherwise.

If Apple Music add-to-playlist fails, show a clear non-fatal error and do not
pretend the promotion succeeded.

### Search and manual add

Users can search Apple Music and manually add tracks to any linked playlist.

Add behaviour:

- User selects the destination playlist.
- Overplay attempts to add the track to the Apple Music playlist.
- On success, Overplay syncs that playlist or inserts the local item using the
  returned identifiers.
- On failure, Overplay displays a clear error.

Manual add should support both the One True Playlist and triage playlists.

## Play/Skip History

Overplay records playlist-specific playthrough and skip counts. Promotion from
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
- The playlist item is active and not locally retired.
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

### Manual retirement

The user can manually retire a track from any linked playlist. Manual
retirement:

- Marks the local playlist item retired.
- Records a manual retirement event. The current data model may store this as
  an eviction event while Retired remains the user-facing term.
- Attempts Apple Music removal if supported.
- Falls back to local filtering if remote removal fails.

The user can restore a retired track. Restore clears the local retirement
state, moves the item to the bottom of the Active list for that playlist, and
makes it eligible for Active playback again.

## Shared vs Device-Local State

The SwiftData store is backed by iCloud so devices on the same account can
share:

- Linked playlist definitions.
- Track metadata snapshots.
- Playlist membership and retirement state.
- Skip and playthrough counts.
- Retirement history.
- Promotion history.
- User-configurable retirement settings.

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
other scene-local storage when a platform supports multiple windows. This is
especially important on iPad and Mac, where two windows may legitimately show
different playlists or views at the same time.

Two devices should be able to share playlist and retirement data without
interfering with each other's playback.

## Playback Order, Shuffle, and Repeat

Overplay owns playback order. SwiftData tracks playlist membership, track
metadata, play/skip history, and retirement state; it does not own playback order or playlist sort
order. Playback order is local, disposable, and keyed by player, Apple Music
playlist, and playlist scope. Each linked playlist has separate **Active** and
**Retired** local orders. There is no separate unshuffled order to restore
during playback.

MusicKit should receive an explicit full queue from Overplay, while MusicKit
shuffle and repeat modes remain off. Overplay owns repeat by reshuffling and
rebuilding the queue when the end is reached. This keeps skip tracking,
retirement filtering, playlist display order, CarPlay, system controls, and
remote commands aligned to the same source of truth.

During playback, the shared playback controller should maintain an active
playlist projection for the currently playing playlist. It should contain
stable playlist item IDs, local track IDs, display metadata, artwork source,
skip and playthrough counts, protected/retired/playable state, and current-row
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

- Starting a playlist sends the full current local order for the selected scope
  to MusicKit.
- If the user starts at a specific track, MusicKit should start at that track
  within the full queue.
- If no track is requested, playback starts at the first track in local order.
- MusicKit and Overplay UI should be reconciled immediately after queue setup so
  every surface agrees on the current track and queue position.
- After queue setup succeeds, the playback controller materializes or refreshes
  the active playlist projection from the same SwiftData records and local
  order used to build the queue.

Shuffle behavior:

- Shuffle is a one-shot action, not a persistent selected mode.
- Pressing shuffle creates a new full-playlist random order, saves it locally,
  sends the full new queue to MusicKit, and restarts playback from the first
  track at position zero.
- The currently or most recently played track must not appear in the top five
  tracks of the new order.
- For playlists with two to four tracks, keep the currently or most recently
  played track out of the first position.
- For a one-track playlist, the single track remains the whole order.
- There is no shuffle-off behavior because there is no preserved unshuffled
  order to return to.

Repeat behavior:

- Playlists always repeat. There is no user-facing repeat button in Overplay's
  iOS or CarPlay UI, and repeat-one is not part of the playback model.
- When the last track is played through or skipped past, Overplay evaluates the
  outgoing track, creates a fresh shuffled order using the same placement rules,
  saves it, sends the full queue to MusicKit, and starts from the first track.
- Queue end is detected from the player state (no current entry while the
  player is stopped or paused) and only triggers the repeat rebuild when the
  outgoing track was observed near its end, so an external stop mid-track or a
  queue that ended unobserved during suspension does not restart playback.
- Platform/system UI may still expose repeat or shuffle concepts, but Overplay
  should keep its own MusicKit shuffle and repeat modes off and treat local
  order as authoritative.

Additions, retirements, and restores:

- Playlist additions from MusicKit sync, SwiftData sync, manual add, or
  promotion append to the end of the current Active local order.
- If the changed playlist is currently playing, playable additions should also
  be appended to the live MusicKit queue when possible without restarting
  playback.
- If the changed playlist is currently playing, refresh the active playlist
  projection immediately after the durable SwiftData/local-order mutation so
  visible rows do not wait for SwiftData query invalidation.
- Retiring a track removes it from Active order and appends it to the bottom of
  Retired order.
- Restoring a track removes it from Retired order and appends it to the bottom
  of Active order.
- For the currently playing playlist, deletion or retirement is recorded in
  SwiftData and local order immediately, but the active MusicKit queue may be
  left alone for the current playthrough. The track disappears on the next
  shuffle, rebuild, or switch back to that playlist.
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
- Skip increments, playthrough counts, playthrough skip resets, keep/protect
  changes, manual resets, retirements, restores, promotions, queue rebuilds, and
  shuffle/order changes refresh the projection after their shared controller or
  use-case mutation succeeds.
- When playback switches to another playlist or clears, discard the old
  projection. The old playlist then renders from SwiftData again.
- If projection refresh fails, keep playback and durable SwiftData state
  authoritative and allow the playlist UI to fall back to SwiftData rows.

## Cross-Surface Playback Consistency

Playback is a shared engine with many surfaces, not a phone-only feature.
Every playback change must be designed so iPhone, iPad, Mac, CarPlay, Lock
Screen, Control Center, AirPods/headset controls, keyboard/media keys, Siri or
shortcut entry points, MusicKit queue state, and system now-playing metadata
agree about the current track, queue, play state, and playback position.

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

Screens should be adaptive rather than separate products. iPhone can present
these as stacked screens. iPad and Mac should use persistent sidebars,
toolbars, inspector-style detail areas, and split layouts when those patterns
make the workflow clearer.

### Permission screen

Purpose: handle Apple Music permission and subscription readiness.

Show:

- Apple Music authorization state.
- Subscription/capability state when available.
- Connect Apple Music action.
- Settings guidance when permission is denied.

Platform notes:

- iPhone and iPad should use a friendly full-screen onboarding surface.
- Mac should use a compact window-friendly state view with clear system
  settings guidance.

### Playlist management screen

Purpose: manage linked Apple Music playlists.

Required capabilities:

- Choose the One True Playlist.
- Add triage playlists.
- Search/filter Apple Music library playlists.
- Show playlist artwork, role, track count, and sync status.
- Manually sync one playlist or all playlists.
- Deactivate or remove a linked triage playlist.

Platform notes:

- iPad and Mac should make playlist management a sidebar/table workflow.
- Mac should expose common actions through toolbar items, context menus, and
  menu commands.

### Dashboard

Purpose: summarize the One True Playlist and triage activity.

Show:

- One True Playlist name.
- Active playable count.
- Count of playable tracks with one or more logged skips.
- Retired count.
- Recently promoted count.
- Triage playlists with unreviewed or high-skip items.
- Actions for play, sync, search, settings, and history.

Platform notes:

- iPhone dashboard should be compact and action-oriented.
- iPad dashboard can show summary sections beside triage queues.
- Mac dashboard should favor dense, sortable, scan-friendly summaries.

### Playlist detail

Purpose: inspect any linked playlist.

Show:

- Segmented Active and Retired lists on iOS.
- Active tracks ordered by the device-local Active playback order.
- Retired tracks ordered by the device-local Retired playback order and
  playable as a playlist context from iOS.
- Skip and playthrough counts.
- Retirement state.
- Last seen in Apple Music.
- Promote action for triage playlist tracks.
- Manual retire/remove action for active tracks.
- Restore action for retired tracks.
- Search/add action scoped to that playlist.

Platform notes:

- iPad and Mac should support table-like scanning and selection.
- Mac should support context menu actions for promote, retire, restore, and
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
- Restore action for retired tracks.
- Promote action when playing from a triage playlist.

The standard media controls should call into a shared playback controller.

Platform notes:

- iPhone should keep Now Playing immersive and touch-first.
- iPad should support Now Playing as a detail pane or separate window.
- Mac should support a compact mini-player style window in addition to the
  full Now Playing view where practical.

### CarPlay music player

Purpose: provide the in-car playback and browsing surface through CarPlay
templates connected to the shared playback controller.

Show:

- One True Playlist playback entry point.
- Active linked playlists.
- The currently playing Retired playlist context if playback was started from
  Retired on iOS.
- Current track title, artist, album, and artwork where CarPlay templates
  support it.
- Play, pause, next, previous, and Now Playing controls.
- Direct Retire button in Now Playing for active tracks.
- Direct Restore button in Now Playing for retired tracks.
- Direct Promote button when the current track belongs to a triage playlist.

Platform notes:

- CarPlay belongs to the iPhone app target and should use CarPlay scene
  configuration.
- CarPlay templates should remain thin and delegate playback, queue building,
  metadata, and command handling to shared services.
- The iPhone SwiftUI shell, iPad target, and Mac target should not import or
  depend on CarPlay-specific types.

### Search

Purpose: search Apple Music and add tracks to any linked playlist.

Show:

- Search field.
- Results with artwork, title, artist, and album.
- Destination playlist selector.
- Add action.

Platform notes:

- iPad and Mac should support faster triage with keyboard focus, return-to-add
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

History must survive sync, relaunch, and iCloud sync.

Platform notes:

- Mac should use a sortable, filterable table for history when practical.
- iPad should support filters without hiding the event list.

### Settings

Purpose: configure behaviour.

Settings:

- One True Playlist.
- Linked triage playlists.
- Skip threshold percentage.
- Minimum listening time before skip can count.
- Playthrough threshold percentage.
- Reset local playback state.
- Reset shared stats and history with destructive confirmation.

Settings should be available on every target. Mac should expose the settings
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
- Own local playback order, one-shot reshuffle/restart behavior, and
  end-of-playlist repeat by rebuilding from a fresh shuffled order.
- Track play sessions.
- Publish current playback state.
- Forward transitions to shared playback evaluation and track action services.
- Keep playback/session state device-local.
- Isolate platform-specific playback or media-session differences behind a
  small adapter if iPhone, iPad, and Mac APIs diverge.

### TrackActionService / EvictionEngine

- Apply skip and playthrough rules.
- Increment/reset counts.
- Manually retire or restore items from any linked playlist.
- Record retirement events. The current implementation may still use eviction
  naming internally.
- Request remote playlist deletion for managed playlists.

### PlaylistMutationService

- Add tracks to managed linked Apple Music playlists.
- Promote tracks from triage playlists to a managed One True Playlist.
- Attempt remote playlist deletion for local retirements when policy allows.
- Return explicit success/failure results.

### SearchService

- Search Apple Music catalogue.
- Return lightweight result models.
- Support manual add to any linked playlist.

### NowPlayingMetadataService

- Publish current metadata to `MPNowPlayingInfoCenter`.
- Keep lock-screen and remote metadata in sync with playback state.

### RemoteCommandService

- Register remote command handlers.
- Forward play, pause, next, previous, and supported shuffle actions to the
  playback controller.
- Avoid retain cycles and clean up handlers when appropriate.
- Support lock-screen, Control Center, headset, keyboard, and Mac media-key
  commands where each platform exposes them.

### PlatformShell

- Provide the root navigation appropriate to each target.
- Share the same view models and services.
- Own platform-specific menu commands, keyboard shortcuts, toolbar placement,
  window commands, and scene setup.
- Keep platform branching out of business logic.

## Suggested Data Model

Exact SwiftData syntax may evolve, but the model should retain these concepts.

### PlaylistRecord

- `id: UUID`
- `musicPlaylistID: String`
- `name: String`
- `role: PlaylistRole`
- `writePolicy: PlaylistWritePolicy`
- `isActive: Bool`
- `lastSyncedAt: Date?`
- `lastSyncError: String?`
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
- `skipCount: Int`
- `playthroughCount: Int`
- `lastPlayedAt: Date?`
- `lastSkippedAt: Date?`
- `lastSeenInPlaylistAt: Date?`
- `evictedAt: Date?` (local retirement timestamp in current code)
- `evictionReason: EvictionReason?` (retirement reason in current code)
- `evictionSource: EvictionSource?` (retirement source in current code)
- `protected: Bool`
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

### SettingsRecord

- `id: UUID`
- `skipThresholdPercentage: Double`
- `minimumSkipListeningSeconds: Double`
- `playthroughThresholdPercentage: Double`
- `createdAt: Date`
- `updatedAt: Date`

## Edge Cases

- Apple Music permission denied or restricted.
- Authorized user without Apple Music playback capability.
- No library playlists.
- One True Playlist deleted or renamed in Apple Music.
- Triage playlist deleted or renamed in Apple Music.
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
- Active and Retired tabs are switched repeatedly while playback is active.
- A Retired playlist is started on iOS while CarPlay is connected.
- iCloud data arrives while a device is actively playing.
- The same iCloud account uses Overplay on iPhone, iPad, and Mac at the same
  time.
- Two iPad or Mac windows show different playlists simultaneously.
- A Mac window is closed while playback continues.
- A hardware keyboard or media key command arrives while a modal sheet is open.
- Platform-specific MusicKit capability differs or is temporarily unavailable.

## CarPlay

CarPlay is a current iPhone-supported product goal. Entitlement requirements
have been met, and the iPhone app target should include a CarPlay music
interface using CarPlay templates.

The app architecture should keep playback, now-playing metadata, and remote
commands independent of SwiftUI views so CarPlay templates use the same shared
services as the phone UI.

CarPlay should support:

- Play One True Playlist.
- Browse active triage playlists.
- Review tracks with logged skips.
- Show the current Retired playlist context when the user started Retired
  playback from iOS.
- Now Playing controls.
- Restore the current track when it belongs to a Retired playlist context.

CarPlay UI logic should remain isolated from the iPhone/iPad SwiftUI shell.
iPad and Mac targets must not depend on CarPlay-specific types or entitlements.

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
- Avoid adding compatibility paths for pre-iOS 26, pre-iPadOS 26, or
  pre-macOS 26 systems.
- Prefer shared SwiftUI views that adapt by size class and platform idiom, but
  create platform-specific shells when a native iPad or Mac pattern is clearer.
- Add keyboard shortcuts and menu commands for common iPad and Mac workflows
  once the underlying action exists.

## Current Product Definition

The product is healthy when a user can:

1. Install and run Overplay on iPhone, iPad, and Mac.
2. Connect Apple Music on each target.
3. Choose a One True Playlist.
4. Link additional triage playlists.
5. Sync all linked playlists.
6. Play any linked playlist in Overplay.
7. Track skips and playthroughs for all linked playlists.
8. Surface skip/playthrough history while leaving retirement to explicit user actions.
9. Manually retire and restore tracks from any linked playlist.
10. Promote triage tracks into the One True Playlist.
11. Search Apple Music and add tracks to any linked playlist.
12. Share playlist, stats, and retirement data across devices through iCloud.
13. Keep each device's current playback state independent.
14. Use native iPad layouts for triage and management.
15. Use native Mac windows, menus, keyboard shortcuts, and media controls for
    management and playback.
16. Use a CarPlay music player for playlist browsing, Now Playing controls,
    and playback through the shared playback controller.
