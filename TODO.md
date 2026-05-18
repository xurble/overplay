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

## Step 4 - Add Repositories for the New Model - Complete

- Add `PlaylistRepository`.
- Add `TrackRecordRepository`.
- Add `PlaylistItemRepository`.
- Replace or expand `EventRepository` to write `HistoryEvent`.
- Keep old repositories working until callers are moved.

Verification:

- Complete: Repository tests cover create, fetch, update, and idempotent upsert.
- Complete: App target builds.
- Complete: Unit tests pass.

## Step 5 - Add One-Way Local Migration - Complete

- Convert `OverplaySettings.selectedPlaylistID/name` into a
  `PlaylistRecord(role: oneTruePlaylist)`.
- Convert each `TrackedTrack` into a `TrackRecord` plus `PlaylistItemRecord`.
- Preserve skip counts, playthrough counts, eviction state, and timestamps.
- Make migration idempotent.

Verification:

- Complete: Existing selected playlist and stats survive after launch.
- Complete: Migration tests pass for empty data and populated legacy data.
- Complete: App target builds.

## Step 6 - Move Dashboard Reads to the New Model - Complete

- Compute known, playable, evicted, and at-risk counts from `PlaylistRecord`
  and `PlaylistItemRecord`.
- Keep the visible dashboard mostly unchanged.
- Leave old model writes in place until sync/playback are migrated.

Verification:

- Complete: Dashboard counts match the old One True Playlist behavior.
- Complete: Unit tests cover count calculations.
- Complete: App target builds.

## Step 7 - Sync a PlaylistRecord - Complete

- Change `PlaylistSyncService` to sync a `PlaylistRecord`.
- Upsert `TrackRecord` and `PlaylistItemRecord` instead of `TrackedTrack`.
- Add `syncAllLinkedPlaylists`.
- Preserve idempotency.

Verification:

- Complete: Syncing the One True Playlist works.
- Complete: Repeated sync does not duplicate tracks.
- Complete: Unit tests cover reconciliation helpers.

## Step 8 - Reconcile Remote Removals - Complete

- During sync, mark missing Apple Music tracks as removed from that linked
  playlist.
- Record a manual removal/history event for synced remote deletions.
- Preserve historical stats and eviction records.
- Exclude removed items from active counts and playback.

Verification:

- Complete: Removing a track in Apple Music then syncing removes it from active Overplay
  views.
- Complete: History still shows the removed item.
- Complete: Reconciliation tests pass.

## Step 9 - Add Linked Playlist Management UI - Complete

- Complete: Replace simple playlist selection with linked playlist management.
- Complete: Allow choosing the One True Playlist.
- Complete: Allow adding triage playlists.
- Complete: Show playlist role, track count, and sync status.
- Complete: Support syncing one playlist or all playlists.

Verification:

- Complete: One True Playlist is still required for the main flow.
- Complete: Triage playlists can be added without affecting existing playback.
- Complete: App target builds.

## Step 10 - Restrict Automatic Eviction to the One True Playlist - Complete

- Complete: Update `EvictionEngine` to check playlist role before count-based eviction.
- Complete: Continue tracking skips and playthroughs for triage playlists.
- Complete: Allow manual eviction from any linked playlist.

Verification:

- Complete: One True Playlist items can auto-evict.
- Complete: Triage items do not auto-evict from skip count.
- Complete: Eviction engine tests cover both roles.

## Step 11 - Update Playback to Use Playlist Context - Complete

- Complete: Change playback entry points to accept a linked playlist.
- Complete: Build queues from active, non-evicted, non-removed playlist items.
- Complete: Preserve device-local playback/session state.
- Complete: Keep current One True Playlist playback button working.

Verification:

- Complete: One True Playlist playback still works.
- Complete: Triage playlist playback works.
- Complete: Playback queue filtering tests pass.

## Step 12 - Add Promotion Flow - Complete

- Complete: Add `PlaylistMutationService.promote(item:)`.
- Complete: Add the track to the Apple Music One True Playlist when possible.
- Complete: Create or reactivate the local One True Playlist item on success.
- Complete: Preserve source triage stats and history.
- Complete: Record a promotion history event.

Verification:

- Complete: Promotion succeeds or fails visibly.
- Complete: Failed promotion does not corrupt local state.
- Complete: Promotion tests cover local state transitions.

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
