# Architecture Refactor Plan

## Goal

Refactor Overplay toward a cleaner, more scalable architecture without a large
"big bang" MVVM rewrite. The first priority is to separate shared presentation
state and focused use cases from oversized services and views. View models
should be introduced only where they reduce screen complexity and make async
workflows easier to test.

Each checkpoint should leave the app compiling, tests passing, and behavior
unchanged unless the checkpoint explicitly says otherwise. Commit after each
checkpoint before moving on.

## Guiding Principles

- Keep each commit small enough to review independently.
- Prefer extracting stable use cases before introducing view models.
- Keep SwiftUI views declarative and thin.
- Make iOS, iPadOS, macOS, and CarPlay consume shared presentation state.
- Avoid moving complexity from large views into equally large view models.
- Improve repository scalability separately from UI refactors.
- Preserve current behavior unless a checkpoint explicitly changes it.

## How To Use This Plan

Treat each checkpoint as a hard stop. Do not begin the next checkpoint until the
current one builds, its tests pass, and the human developer has reviewed and
committed the work.

For larger checkpoints, especially queue/mode coordination and screen view
models, split the checkpoint into smaller commits if the diff becomes difficult
to review.

## Checkpoint 1: Add Shared Presentation Models

### Goal

Introduce neutral, testable display models without changing UI behavior.

### Create

- `Overplay/Presentation/PlaylistSummaryPresentation.swift`
- `Overplay/Presentation/TrackSummaryPresentation.swift`
- `Overplay/Presentation/NowPlayingPresentation.swift`
- `Overplay/Presentation/TrackHealthPresentation.swift`
- `Overplay/Presentation/PlaybackControlsPresentation.swift`

### Move Into Presentation Models

- Playlist role title, icon intent, and display priority.
- Writable/incoming-only labels.
- Track subtitle formatting.
- Skip count labels.
- Health status labels.
- Now-playing title, artist, album, and progress text.
- Shuffle and repeat display state.

### Replace Initial Call Sites

- `DashboardView`
- `PlaylistSelectionView`
- `NowPlayingView`
- `CarPlayLibrarySnapshot`

### Tests

- Add focused tests for role labels, ordering intent, track subtitles, health
  labels, and progress formatting.

### Commit Criteria

- App builds.
- Existing tests pass.
- New presentation tests pass.
- No user-visible behavior changes.

## Checkpoint 2: Extract Playlist Presentation Builder

### Goal

Make iOS and CarPlay playlist and track lists share the same source of truth.

### Create

- `Overplay/Presentation/PlaylistPresentationBuilder.swift`

### Responsibilities

- Build playlist summaries from `PlaylistRecord`, `PlaylistItemRecord`, and
  `TrackRecord` data.
- Build track summaries for playlist screens and CarPlay lists.
- Centralize playlist ordering:
  - One True Playlist first.
  - Triage playlists after.
  - Case-insensitive name sort within each role.
- Centralize representative artwork selection.
- Centralize known/playable/evicted/at-risk counts.

### Replace Logic In

- `DashboardView`
- `PlaylistSelectionView`
- `CarPlayLibrarySnapshot`

`CarPlayLibrarySnapshot` can remain as a CarPlay adapter, but it should wrap the
shared builder instead of owning parallel summary logic.

### Tests

- Update `CarPlayLibrarySnapshotTests`.
- Add presentation-builder tests for ordering, counts, role grouping, and empty
  states.

### Commit Criteria

- iOS playlist ordering is unchanged.
- CarPlay playlist ordering is unchanged.
- Playlist counts match existing behavior.
- Snapshot/presentation tests pass.

## Checkpoint 3: Fix Repository Scalability

### Goal

Reduce fetch-all/filter-in-memory patterns before layering more architecture on
top.

### Add Predicate-Based Repository APIs

- `PlaylistRepository.activePlaylists(in:)`
- `PlaylistRepository.playlist(id:in:)`
- `PlaylistRepository.playlist(musicPlaylistID:in:)`
- `PlaylistRepository.oneTruePlaylist(in:)`
- `PlaylistItemRepository.items(forPlaylistID:in:)`
- `PlaylistItemRepository.playableItems(forPlaylistID:in:)`
- `PlaylistItemRepository.activeItems(forPlaylistID:in:)`
- `TrackRecordRepository.tracks(ids:in:)`
- `TrackRecordRepository.track(id:in:)`
- `TrackRecordRepository.track(musicItemID:in:)`

### Replace Risky Dictionary Construction

Replace `Dictionary(uniqueKeysWithValues:)` where duplicate keys could crash
with safe helpers, such as:

- first value wins
- last value wins
- grouping by key
- explicit duplicate assertion in tests only

### Tests

- Update repository tests to verify predicate-scoped fetches.
- Add tests for duplicate-safe dictionary helper behavior.

### Commit Criteria

- Repository tests pass.
- Playback/order tests pass.
- No behavior changes except improved duplicate tolerance.

## Checkpoint 4: Extract Track Health Use Case

### Goal

Remove duplicated iOS and CarPlay track-health mutation logic.

### Create

- `Overplay/UseCases/TrackHealthActionService.swift`

### Responsibilities

- Keep current track.
- Reset current skip count.
- Protect current track.
- Evict current track.
- Restore evicted playlist item.
- Log the appropriate history events.
- Save model context or surface errors consistently.

### Move Logic From

- `PlaybackController.keepCurrent`
- `PlaybackController.evictCurrent`
- `CarPlayCoordinator.resetCurrentSkipCount`
- `CarPlayCoordinator.protectCurrentTrack`
- `HistoryView.restore`

`PlaybackController` and `CarPlayCoordinator` may still call the new service at
this checkpoint.

### Tests

- Keep current track resets skip count and optionally protects.
- Reset skip count logs history.
- Protect current track logs history.
- Evict current track updates local state and remote mutation policy remains
  respected.
- Restore clears eviction state and logs history.

### Commit Criteria

- iOS Keep and Evict buttons still work.
- CarPlay health actions still work.
- Track-health tests pass.

## Checkpoint 5: Extract Playback Session Evaluation

### Goal

Shrink `PlaybackController` without changing playback behavior.

### Create

- `Overplay/UseCases/PlaybackSessionEvaluationService.swift`

### Responsibilities

- Bootstrap playback sessions.
- Evaluate skip transitions.
- Evaluate playthrough thresholds.
- Mark sessions as evaluated without skip.
- Trigger eviction workflow when a threshold is crossed.
- Return explicit outcomes for the controller to react to.

### Move Logic From

- `PlaybackController.evaluatePlaythroughIfNeeded`
- `PlaybackController.evaluateActiveSession`
- `PlaybackController.bootstrapActiveSession`
- `PlaybackController.markActiveSessionEvaluatedWithoutSkip`
- Related private session-resolution helpers where practical.

### Tests

- Existing `EvictionEngineTests`.
- Existing `PlaybackSessionSupportTests`.
- New service tests for skip, natural completion, playthrough, and protected
  track cases.

### Commit Criteria

- Playback behavior is unchanged.
- Session evaluation tests pass.
- Existing playback-controller display restore tests pass.

## Checkpoint 6: Extract Queue And Mode Coordination

### Goal

Isolate shuffle, repeat, queue rebuilding, and local-track ordering complexity.

### Create

- `Overplay/Playback/PlaybackQueueCoordinator.swift`
- `Overplay/Playback/PlaybackModeCoordinator.swift`

### Responsibilities

`PlaybackQueueCoordinator`:

- Build cached queue entries.
- Decode cached MusicKit tracks.
- Resolve local track IDs.
- Reconcile local playlist items with MusicKit queue entries.
- Build transition queues.

`PlaybackModeCoordinator`:

- Read and write shuffle/repeat state.
- Reconcile stored shuffle order.
- Build repeat queue restart order.
- Handle pending mode queue rebuild decisions.

### Move Logic From

- `PlaybackController.orderedQueueEntries`
- `PlaybackController.orderedCachedQueueEntries`
- `PlaybackController.cachedQueueEntry`
- `PlaybackController.orderedLocalTrackIDs`
- `PlaybackController.localTrackID`
- `PlaybackController.reconcileStoredOrder`
- Repeat and pending-mode queue rebuild helpers.

### Tests

- Existing `PlaybackOrderEngineTests`.
- Existing `PlaybackQueueBuilderTests`.
- Existing `PlaybackModeStoreTests`.
- New queue/mode coordinator tests for current-track retention and repeat
  restart.

### Commit Criteria

- Playback/order tests pass.
- Manual smoke test:
  - Play playlist.
  - Next.
  - Previous.
  - Shuffle on/off.
  - Repeat on/off.
  - End-of-queue repeat.

## Checkpoint 7: Thin PlaybackController

### Goal

Make `PlaybackController` an application-facing coordinator instead of a god
object.

### Keep In PlaybackController

- Observable current playback state.
- MusicKit transport calls.
- Monitoring loop.
- Current playback display restore.
- Coordination between extracted services.

### Move Out If Still Present

- Business rules.
- Remote playlist mutation decisions.
- Track-health mutations.
- Queue-order algorithms.
- Formatting or display text.
- Test-only logic that can be covered through injected collaborators.

### Tests

- Full playback-related suite.
- Existing display restore tests.
- Manual playback smoke test.

### Commit Criteria

- `PlaybackController` is substantially smaller and has a narrow role.
- Existing playback behavior remains intact.
- Full test suite passes.

## Checkpoint 8: Extract App Startup View Model

### Goal

Remove startup and service lifecycle orchestration from `AppRouter`.

### Create

- `Overplay/App/AppStartupViewModel.swift`

### Responsibilities

- Settings bootstrap.
- Authorization refresh.
- Permission gate state.
- Remote command activation.
- Authorized service startup and stop.
- Local playback display restore.
- Periodic playlist sync startup.
- `hasStartedAuthorizedServices` state.

### Move Logic From

- `AppRouter.task`
- `AppRouter.onChange(of: authorizationService.readiness.isReady)`
- `AppRouter.startAuthorizedServices`
- `AppRouter.shouldShowPermissionView`

### Tests

- Update startup authorization tests.
- Add tests for first authorized startup, repeated authorized startup, and
  transition back to unauthorized.

### Commit Criteria

- Cold launch still shows preparing, permission, or authorized UI correctly.
- Authorized services start once.
- Periodic sync stops when readiness becomes unavailable.

## Checkpoint 9: Split AppRouter And Shell Views

### Goal

Make navigation and shell ownership obvious, and remove duplicated now-playing
UI.

### Move Files

- `PlatformShell`
- `CompactAppShell`
- `SplitAppShell`
- `PlayerSheetView`
- `MiniPlayerLozengeView`
- `NowPlayingPaneView`

Suggested destinations:

- `Overplay/App/Shell/`
- `Overplay/Views/NowPlaying/`

### Extract Shared Now-Playing Components

- `NowPlayingArtworkView`
- `NowPlayingTrackTextView`
- `NowPlayingProgressView`
- `TrackHealthStatusView`
- `PlaybackModeControlsView`
- `TrackActionControlsView`

Use these from both the sheet/pane version and the full `NowPlayingView`.

### Tests

- Preview compile check.
- No new business-logic tests required unless behavior changes.

### Commit Criteria

- `AppRouter` handles routing only.
- Full now-playing screen and mini-player/pane share components.
- Previews compile.
- UI behavior is unchanged.

## Checkpoint 10: Introduce Screen View Models Where Useful

### Goal

Introduce MVVM selectively for screens with meaningful workflow state.

### Suggested Order

Commit each screen separately.

1. `PlaylistSelectionViewModel`
2. `SearchMusicViewModel`
3. `PlaylistManagementViewModel`
4. `SettingsViewModel`
5. `HistoryViewModel`

### Move Into View Models

- Loading flags.
- Selected playlist state.
- User-facing messages.
- Async sync/add/promote/diagnostics actions.
- Derived row models.
- Error handling.

### Keep In Views

- Layout.
- Styling.
- Navigation destinations.
- Simple view-only state such as disclosure or confirmation dialogs, unless a
  dialog is tightly coupled to a use case.

### Tests

- Add view-model tests for each moved workflow.
- Use in-memory SwiftData containers.
- Use lightweight service fakes where MusicKit work would otherwise be required.

### Commit Criteria

- Each screen remains behaviorally equivalent after its own commit.
- View body complexity is reduced.
- View-model tests pass.

## Checkpoint 11: Make CarPlay A Presentation Adapter

### Goal

Ensure iOS and CarPlay share presentation and use-case code instead of drifting.

### Keep In CarPlayCoordinator

- `CPTemplate` creation.
- CarPlay navigation.
- Button wiring.
- CarPlay-specific refresh timing.
- CarPlay-specific error presentation.

### Move Out Or Delegate

- Playlist ordering decisions.
- Track summary formatting.
- Track-health action behavior.
- Playback mode action behavior.
- Now-playing state derivation.

### Shared Inputs

CarPlay should consume:

- `PlaylistSummaryPresentation`
- `TrackSummaryPresentation`
- `NowPlayingPresentation`
- `TrackHealthPresentation`
- `TrackHealthActionService`
- Shared playback mode actions

### Tests

- Update CarPlay snapshot tests.
- Add tests proving SwiftUI and CarPlay playlist summaries are built from the
  same presentation builder.

### Commit Criteria

- CarPlay UI content matches iOS source-of-truth ordering and labels.
- CarPlay coordinator is smaller and adapter-focused.
- CarPlay tests pass.
- Manual CarPlay simulator or device smoke test if available.

## Checkpoint 12: Clean Up Remote Command Service

### Goal

Avoid stale captured model contexts and one-shot global state.

### Refactor

Replace one-shot `install` behavior with a lifecycle API such as:

- `activate(playbackController:context:)`
- `update(playbackController:context:)`
- `deactivate()`
- `syncPlaybackModes(from:)`

If MediaPlayer target removal is available for the installed commands, store
target tokens and remove them during deactivation.

### Tests

- Existing remote playback mode mapper tests.
- Add a small service-state test if command-center interaction can be isolated.

### Commit Criteria

- Remote commands use current dependencies after scene or CarPlay reconnects.
- No duplicate command handlers are registered.
- Manual lock-screen or Control Center command smoke test.

## Checkpoint 13: Add MusicKit Playlist Pagination

### Goal

Fix the 100-playlist discovery cap.

### Refactor

Update `PlaylistSyncService.fetchAllLibraryPlaylists()` so it pages through all
available playlist results if MusicKit exposes continuation or paging APIs.

If MusicKit does not provide a supported continuation API for this request,
document the limitation in code and in this plan, then isolate playlist fetching
behind a testable wrapper so it can be changed later without touching views.

### Tests

- Add tests around the playlist-fetching wrapper using fake paged responses.
- Verify sorting still pins preferred Overplay playlists first.

### Commit Criteria

- Large libraries are no longer silently capped when paging is available.
- The limitation is explicit if paging is not available.
- Playlist discovery tests pass.

## Checkpoint 14: Final Naming And Organization Cleanup

### Goal

Remove naming drift, dead code, and file organization debt left by the staged
refactor.

### Clean Up

- Rename `EvictionHistoryView.swift` or split it so the file matches
  `HistoryView`.
- Move `PlaylistManagementView` out of `DashboardView.swift`.
- Remove obsolete typealiases.
- Remove duplicate formatter functions.
- Remove old test-only hooks if covered through injected services.
- Review previews after file moves.
- Review folder names for consistency.

### Tests

- Full test suite.
- Project build.
- Preview compile check where practical.
- Manual smoke test across main app flows.

### Commit Criteria

- File and type names align.
- Duplicate presentation logic is removed.
- Full suite passes.
- Manual smoke test passes.

## Recommended Sequence

1. Add shared presentation models.
2. Extract playlist presentation builder.
3. Fix repository scalability.
4. Extract track health use case.
5. Extract playback session evaluation.
6. Extract queue and mode coordination.
7. Thin `PlaybackController`.
8. Extract app startup view model.
9. Split router and shell views.
10. Add screen view models one screen at a time.
11. Make CarPlay a presentation adapter.
12. Clean up remote command service.
13. Add MusicKit playlist pagination.
14. Finish naming and organization cleanup.

## Definition Of Done

The refactor is done when:

- SwiftUI views mostly render state and send user intents.
- View models exist only for screens with real workflow state.
- Business rules live in focused use-case services.
- Repositories provide scoped data access.
- `PlaybackController` coordinates playback instead of owning every playback
  concern.
- CarPlay and SwiftUI share presentation builders and use cases.
- Duplicate formatting and state derivation are removed.
- The full test suite passes.
- iOS and CarPlay manual smoke tests pass where available.

## Document Review

This plan intentionally starts with shared presentation and use-case seams
rather than a full MVVM conversion. That order keeps risk lower because it
first removes duplication and business logic from overloaded services. View
models are introduced later, screen by screen, after the underlying use cases
are small enough to compose.

The highest-risk checkpoints are Checkpoint 6 and Checkpoint 7 because queue
ordering, shuffle, repeat, and playback restoration are tightly coupled to live
MusicKit behavior. Those checkpoints should be treated as mechanical refactors
with strong tests and manual playback smoke tests before commit.

The plan is long, but the sequence is deliberately conservative: each checkpoint
has a clear goal, test expectations, and commit criteria. If any checkpoint
starts to produce broad unrelated changes, stop and split it into a smaller
checkpoint before continuing.
