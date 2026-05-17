# Overplay Migration Todo

This plan moves the current single-playlist implementation toward the agreed
long-term design in small, committable steps. Each step should leave the app
buildable, and the One True Playlist flow should remain usable throughout.

## Step 0 - Add Unit Test Foundation - Complete

- Add a unit test target for shared Overplay logic.
- Prefer Swift Testing for new tests unless Xcode/project constraints make
  XCTest simpler.
- Add lightweight in-memory SwiftData test helpers.
- Add first smoke tests for settings defaults, track repository upsert, and
  eviction skip/playthrough decisions.
- Make `xcodebuild test` or the Xcode test action part of normal verification.

Verification:

- Complete: App target builds.
- Complete: Test target builds.
- Complete: Initial tests pass.

## Step 1 - Commit Documentation Baseline - Complete

- Commit `README.md`.
- Commit `OVERPLAY_DESIGN_SPEC.md`.
- Commit updated `AGENTS.md`.
- Commit removal/rename cleanup for the old proof-of-concept document.

Verification:

- Complete: Repo has no remaining proof-of-concept wording.
- Complete: App target still builds.

## Step 2 - Add Domain Vocabulary - Complete

- Add typed enums for playlist role, history event type, history event source,
  eviction reason, eviction source, and remote mutation status.
- Keep these types independent of SwiftData at first.
- Add unit tests for raw values/codable persistence expectations where useful.

Verification:

- Complete: App target builds.
- Complete: Unit tests pass.
- Complete: No behavior changes.

## Step 3 - Add New SwiftData Models Alongside Existing Models - Complete

- Add `PlaylistRecord`.
- Add `TrackRecord`.
- Add `PlaylistItemRecord`.
- Add `HistoryEvent`.
- Add expanded settings fields or a new settings model as needed.
- Keep existing `TrackedTrack`, `PlaybackEvent`, and `OverplaySettings` in
  place for now.

Verification:

- Complete: App launches with the expanded schema.
- Complete: Previews compile.
- Complete: Unit tests pass with in-memory model containers.

## Step 4 - Add Repositories for the New Model

- Add `PlaylistRepository`.
- Add `TrackRecordRepository`.
- Add `PlaylistItemRepository`.
- Replace or expand `EventRepository` to write `HistoryEvent`.
- Keep old repositories working until callers are moved.

Verification:

- Repository tests cover create, fetch, update, and idempotent upsert.
- App target builds.
- Unit tests pass.

## Step 5 - Add One-Way Local Migration

- Convert `OverplaySettings.selectedPlaylistID/name` into a
  `PlaylistRecord(role: oneTruePlaylist)`.
- Convert each `TrackedTrack` into a `TrackRecord` plus `PlaylistItemRecord`.
- Preserve skip counts, playthrough counts, eviction state, and timestamps.
- Make migration idempotent.

Verification:

- Existing selected playlist and stats survive after launch.
- Migration tests pass for empty data and populated legacy data.
- App target builds.

## Step 6 - Move Dashboard Reads to the New Model

- Compute known, playable, evicted, and at-risk counts from `PlaylistRecord`
  and `PlaylistItemRecord`.
- Keep the visible dashboard mostly unchanged.
- Leave old model writes in place until sync/playback are migrated.

Verification:

- Dashboard counts match the old One True Playlist behavior.
- Unit tests cover count calculations.
- App target builds.

## Step 7 - Sync a PlaylistRecord

- Change `PlaylistSyncService` to sync a `PlaylistRecord`.
- Upsert `TrackRecord` and `PlaylistItemRecord` instead of `TrackedTrack`.
- Add `syncAllLinkedPlaylists`.
- Preserve idempotency.

Verification:

- Syncing the One True Playlist works.
- Repeated sync does not duplicate tracks.
- Unit tests cover reconciliation helpers.

## Step 8 - Reconcile Remote Removals

- During sync, mark missing Apple Music tracks as removed from that linked
  playlist.
- Record a manual removal/history event for synced remote deletions.
- Preserve historical stats and eviction records.
- Exclude removed items from active counts and playback.

Verification:

- Removing a track in Apple Music then syncing removes it from active Overplay
  views.
- History still shows the removed item.
- Reconciliation tests pass.

## Step 9 - Add Linked Playlist Management UI

- Replace simple playlist selection with linked playlist management.
- Allow choosing the One True Playlist.
- Allow adding triage playlists.
- Show playlist role, track count, and sync status.
- Support syncing one playlist or all playlists.

Verification:

- One True Playlist is still required for the main flow.
- Triage playlists can be added without affecting existing playback.
- App target builds.

## Step 10 - Restrict Automatic Eviction to the One True Playlist

- Update `EvictionEngine` to check playlist role before count-based eviction.
- Continue tracking skips and playthroughs for triage playlists.
- Allow manual eviction from any linked playlist.

Verification:

- One True Playlist items can auto-evict.
- Triage items do not auto-evict from skip count.
- Eviction engine tests cover both roles.

## Step 11 - Update Playback to Use Playlist Context

- Change playback entry points to accept a linked playlist.
- Build queues from active, non-evicted, non-removed playlist items.
- Preserve device-local playback/session state.
- Keep current One True Playlist playback button working.

Verification:

- One True Playlist playback still works.
- Triage playlist playback works.
- Playback queue filtering tests pass.

## Step 12 - Add Promotion Flow

- Add `PlaylistMutationService.promote(item:)`.
- Add the track to the Apple Music One True Playlist when possible.
- Create or reactivate the local One True Playlist item on success.
- Preserve source triage stats and history.
- Record a promotion history event.

Verification:

- Promotion succeeds or fails visibly.
- Failed promotion does not corrupt local state.
- Promotion tests cover local state transitions.

## Step 13 - Update Search and Manual Add

- Add destination playlist selection to search.
- Allow manual add to the One True Playlist or any triage playlist.
- Sync or locally insert/update after successful add.
- Show clear errors when Apple Music mutation fails.

Verification:

- Add to One True Playlist works or fails gracefully.
- Add to triage playlist works or fails gracefully.
- Mutation service tests cover success and failure results.

## Step 14 - Expand History Screen

- Replace eviction-only history with unified history.
- Show evictions, removals, promotions, restores, and remote mutation outcomes.
- Include playlist, event source, count/manual flag, dates, and restore actions
  where appropriate.

Verification:

- Existing eviction events remain visible.
- New promotion and removal events appear.
- History filtering/sorting tests pass where logic is extracted.

## Step 15 - Audit Shared vs Device-Local State

- Keep shared playlist, track, stats, settings, and history data in SwiftData.
- Move transient playback and navigation state to `AppStorage`, `SceneStorage`,
  or other local-only storage.
- Ensure current playback state does not sync through CloudKit.

Verification:

- Two devices/windows can show different selected views.
- Playback state is not represented in shared SwiftData records.
- App target builds.

## Step 16 - Introduce Adaptive Platform Shell

- Add a root shell that chooses appropriate navigation per platform/size.
- Keep compact `NavigationStack` behavior for iPhone.
- Use split navigation for iPad and Mac-capable layouts.
- Keep business logic out of platform branching.

Verification:

- iPhone flow remains familiar.
- iPad layout uses a sidebar.
- App target builds.

## Step 17 - Refine iPad Experience

- Improve playlist management, playlist detail, history, and Now Playing in
  split layouts.
- Add iPad toolbar actions.
- Add useful hardware keyboard shortcuts where actions already exist.
- Support Stage Manager and multiwindow-friendly state.

Verification:

- iPad simulator layout is not stretched phone UI.
- Keyboard shortcuts do not break touch workflows.
- App target builds.

## Step 18 - Add Mac Target

- Add a native SwiftUI macOS target sharing models, repositories, services, and
  reusable views.
- Start with dashboard, playlist management, history, settings, and read-only
  data sync if playback needs a later slice.
- Isolate platform-specific media APIs behind adapters.

Verification:

- macOS target builds.
- Shared unit tests still pass.
- No iOS-only APIs leak into shared code.

## Step 19 - Add Mac Interaction Polish

- Add menu commands.
- Add keyboard shortcuts.
- Add context menus.
- Add table-style history and playlist lists where useful.
- Add media-key and Now Playing support where available.
- Support a compact mini-player window if practical.

Verification:

- Mac workflows feel native.
- Media commands are local to the Mac.
- macOS target builds.

## Step 20 - Remove Legacy Model Usage

- Remove `TrackedTrack`-centric code once all reads and writes use the new
  model.
- Remove `PlaybackEvent` if `HistoryEvent` has fully replaced it.
- Remove migration shims only when development CloudKit data strategy is clear.
- Keep any required migration code documented.

Verification:

- Full iPhone/iPad/Mac build matrix passes.
- Unit tests pass.
- No callers remain for legacy repositories or models.
