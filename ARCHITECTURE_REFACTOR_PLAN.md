# Architecture Refactor Plan

## Design Goals

Refactor Overplay toward a cleaner, more scalable architecture **without** a
large "big bang" MVVM rewrite.

The architecture should look like this when finished:

```
Views          → render presentation state, send user intents
View models    → screen workflow state only (where it earns its keep)
Use cases      → business rules and mutations
Presentation   → shared display models and builders (iOS, iPad, Mac, CarPlay)
Playback       → queue/mode coordination separate from transport
Repositories   → scoped, predicate-based data access
PlaybackController → observable playback state + MusicKit transport + coordination
CarPlay        → thin adapter over shared presentation and use cases
```

### Priorities

1. **Separate shared presentation state** from oversized views and services.
2. **Extract focused use cases** before introducing view models.
3. **Introduce view models selectively** only where they reduce screen complexity
   and make async workflows easier to test.
4. **Improve repository scalability** so UI refactors are not built on
   fetch-all/filter-in-memory patterns.
5. **Keep iOS, iPadOS, macOS, and CarPlay** on the same presentation and
   use-case source of truth.

### Guiding Principles

- Keep each commit small enough to review independently.
- Prefer extracting stable use cases before introducing view models.
- Keep SwiftUI views declarative and thin.
- Make all platforms consume shared presentation state.
- Avoid moving complexity from large views into equally large view models.
- Improve repository scalability separately from UI refactors.
- Preserve current behavior unless a checkpoint explicitly changes it.

### How To Use This Plan

Treat each checkpoint as a hard stop. Do not begin the next checkpoint until the
current one builds, its tests pass, and the human developer has reviewed and
committed the work.

Split larger checkpoints into smaller commits if the diff becomes difficult to
review.

---

## Progress So Far

**Status: complete.** Checkpoints 1–20 are done. The full test suite passes on
iOS Simulator (iPhone 17).

### Completed Checkpoints

| # | Checkpoint | Status |
|---|------------|--------|
| 1–14 | Original architecture refactor | **Done** |
| 15 | Unify CarPlay track presentation | **Done** |
| 16 | Share now-playing presentation with CarPlay | **Done** |
| 17 | Finish thinning PlaybackController | **Done** |
| 18 | Replace fetch-all patterns | **Done** |
| 19 | File organization and safety cleanup | **Done** |
| 20 | Final verification | **Done** |

### Definition Of Done

| Criterion | Met? |
|-----------|------|
| Views mostly render + send intents | Yes |
| View models only where needed | Yes |
| Business rules in focused use-case services | Yes |
| Scoped repository access | Yes |
| `PlaybackController` coordinates, doesn't own everything | Yes (~1,090 lines; queue/restoration/metadata extracted) |
| CarPlay + SwiftUI share builders and use cases | Yes |
| Duplicate formatting removed | Yes |
| Full test suite passes | Yes |

### Key Artifacts

- **Presentation:** `PlaylistPresentationBuilder`, `NowPlayingPresentationFactory`, shared now-playing components
- **Use cases:** `TrackHealthActionService`, `PlaybackSessionEvaluationService`
- **Playback:** `PlaybackQueueOrchestrator`, `PlaybackRestorationService`, `PlaybackTrackMetadataSync`, queue/mode coordinators
- **App shell:** `PlatformShell`, `CompactAppShell`, `SplitAppShell`, routing-only `AppRouter`
- **CarPlay:** `CarPlayLibrarySnapshot` adapter, presentation-derived button signatures

---

## Remaining Work

None. The refactor is complete. Checkpoints 15–20 are archived below for history.

<details>
<summary>Checkpoints 15–20 (completed finish work)</summary>

**Goal:** Make CarPlay track lists use the same builder as iOS so formatting and
ordering cannot drift.

**Problem:** `CarPlayLibrarySnapshot.playlistSummaries` wraps
`PlaylistPresentationBuilder`, but `trackSummaries` manually constructs
`TrackSummaryPresentation` and duplicates shuffle-order logic that lives in
`PlaylistDisplayOrder`.

**Refactor**

- Add shuffle-order support to `PlaylistPresentationBuilder.trackSummaries(forPlaylistID:playbackModeState:)`
  (or a small helper the builder calls).
- Change `CarPlayLibrarySnapshot.trackSummaries` to delegate to the builder.
- Update `PlaylistManagementView`, `PlaylistSelectionView`, and any other
  track-list call sites to use the same builder entry point if they don't already.
- Remove the private `areItemsInPlaylistOrder` helper from `CarPlayLibrarySnapshot`
  once the builder owns ordering.

**Tests**

- Existing `CarPlayLibrarySnapshotTests` must continue to pass (equivalence is
  already asserted — simplify the snapshot, keep the tests).
- Add a builder test for shuffle-ordered track summaries if not already covered
  by `PlaylistPresentationBuilderTests`.

**Commit criteria**

- CarPlay and iOS track list labels, skip counts, and ordering match.
- `CarPlayLibrarySnapshot` contains no track-formatting logic beyond delegation.
- CarPlay tests pass.

---

### Checkpoint 16: Share Now-Playing Presentation With CarPlay

**Goal:** CarPlay now-playing UI derives state from the same presentation models
as SwiftUI.

**Problem:** SwiftUI uses `NowPlayingPresentationFactory` →
`NowPlayingPresentation` / `TrackHealthPresentation`. CarPlay reads
`PlaybackController` display properties directly via
`CarPlayNowPlayingButtonSignature`.

**Refactor**

- Extend `NowPlayingPresentationFactory` (or add a CarPlay-facing helper) to
  produce `NowPlayingPresentation` and `TrackHealthPresentation` from a
  `PlaybackController` + settings/context.
- Build `CarPlayNowPlayingButtonSignature` from presentation models instead of
  raw controller properties.
- Where CarPlay shows track-health button titles or labels, use
  `TrackHealthPresentation` label/icon intent.
- Keep `TrackHealthActionService` as the mutation path (already done).

**Tests**

- Extend `CarPlayNowPlayingButtonSignatureTests` to assert signature changes
  match presentation model changes.
- Add presentation-factory tests for edge cases: no current track, evicted,
  protected, at-risk skip count.

**Commit criteria**

- CarPlay button enablement and labels track SwiftUI now-playing state.
- No duplicate now-playing label/formatting logic in `CarPlayCoordinator`.
- CarPlay tests pass.
- Manual CarPlay now-playing smoke test if available.

---

### Checkpoint 17: Finish Thinning PlaybackController

**Goal:** Reduce `PlaybackController` to an application-facing coordinator (~800
lines or fewer) that owns observable state, MusicKit transport, monitoring, and
service coordination — not business rules.

**Problem:** Coordinators and use cases are extracted, but the controller still
contains thin wrapper methods, queue-orchestration glue, and test-only hooks
(`evaluateActiveSessionForTesting`, `markActiveSessionEvaluatedWithoutSkipForTesting`).

**Refactor**

Move remaining logic out in small slices:

1. **Queue orchestration facade** — group the `orderedQueueEntries`,
   `orderedCachedQueueEntries`, `rebuildCurrentQueue`, `handleQueueEnded`, and
   `applyPendingModeQueueRebuild` wrappers into a private `PlaybackQueueOrchestrator`
   or extend `PlaybackQueueCoordinator` with a higher-level API the controller calls.
2. **Restoration** — extract `restoreLocalPlaybackState`,
   `restoreLocalPlaybackDisplay`, and related helpers into
   `PlaybackRestorationService` under `Overplay/Playback/`.
3. **Metadata sync** — extract `refreshCurrentTrackMetadata`,
   `syncPlaybackMetadata`, `prefetchCurrentArtworkIfNeeded` into
   `NowPlayingMetadataService` (or extend the existing service if appropriate).
4. **Test hooks** — remove `ForTesting` methods; cover session evaluation through
   `PlaybackSessionEvaluationService` tests and injected collaborators in
   `PlaybackControllerDisplayRestoreTests`.

**Keep in PlaybackController**

- Observable playback state (`currentTrack`, `elapsedSeconds`, etc.).
- MusicKit transport (`play`, `pause`, `next`, `previous`).
- Monitoring loop and local state persistence.
- Public API surface consumed by views, CarPlay, and remote commands.

**Tests**

- Full playback-related suite must pass unchanged.
- `PlaybackControllerDisplayRestoreTests` updated to avoid test-only controller API.
- Manual playback smoke test: play, next, previous, shuffle, repeat, end-of-queue
  repeat, keep, evict.

**Commit criteria**

- `PlaybackController` is substantially smaller with a documented, narrow role.
- No `ForTesting` methods on production types.
- Playback behavior unchanged.

---

### Checkpoint 18: Replace Remaining Fetch-All Patterns

**Goal:** Views and adapters load only the data they need.

**Problem:** Predicate-scoped repository APIs exist, but several call sites still
fetch entire tables:

- `DashboardView` — `@Query` on all playlists, items, and tracks.
- `HistoryView` — `@Query` on all playlists, items, tracks, and events.
- `CarPlayLibrarySnapshot.playlistSummaries` — `PlaylistItemRepository.allItems(in:)`.
- `TrackRecordRepository.resetPlaylistStats` — fetches all playlist items.

**Refactor**

- **Dashboard:** Replace broad `@Query` with scoped fetches. Options (pick the
  simplest that preserves SwiftUI reactivity):
  - Fetch active playlists via `PlaylistRepository.activePlaylists`, then
    batch-fetch items/tracks for those playlist IDs only.
  - Or use a lightweight `@Observable` dashboard data source refreshed on
    `modelContext` changes.
- **History:** Scope event query with the selected filter predicate; fetch
  playlists/tracks referenced by visible events only (or by timeline builder input).
- **CarPlay snapshot:** Replace `allItems` with items for active playlist IDs only.
- **Reset stats:** Add `PlaylistItemRepository.allItems(in:)` →
  `resetAllStats(in:)` that operates via a single fetch descriptor with no
  in-memory filtering, or batch by playlist if needed.

**Tests**

- Repository tests for any new batch/scoped APIs.
- Dashboard and history behavior unchanged (existing summary/timeline tests).
- CarPlay snapshot tests still pass.

**Commit criteria**

- No view or adapter fetches an entire table when it only needs a subset.
- Repository tests pass.
- No user-visible behavior changes.

---

### Checkpoint 19: File Organization And Safety Cleanup

**Goal:** Clear the organization and safety debt left by the staged refactor.

**Refactor**

File splits (optional but recommended for reviewability):

- `Overplay/App/Shell/PlatformShell.swift`
- `Overplay/App/Shell/CompactAppShell.swift`
- `Overplay/App/Shell/SplitAppShell.swift`
- `Overplay/Views/NowPlaying/MiniPlayerLozengeView.swift`
- `Overplay/Views/NowPlaying/NowPlayingPaneView.swift`

Safety and dead-code cleanup:

- Replace `Dictionary(uniqueKeysWithValues:)` in `PlaybackQueueBuilder` with
  `firstValueDictionary` (or explicit duplicate handling + test).
- Remove any obsolete typealiases or duplicate formatter functions found during
  the above checkpoints.
- Review all `#Preview` blocks after file moves.

**Tests**

- Full test suite.
- Preview compile check where practical.

**Commit criteria**

- File and type names align with their contents.
- No remaining `uniqueKeysWithValues` crash paths in production code.
- Full suite passes.

---

### Checkpoint 20: Final Verification

**Goal:** Confirm the refactor meets the Definition Of Done.

**Manual smoke tests**

- Cold launch: preparing → permission → authorized UI.
- Dashboard, playlist management, search, history, settings.
- Full now-playing: play, pause, next, previous, shuffle, repeat, keep, evict.
- Lock-screen / Control Center remote commands.
- CarPlay: playlist list, track list, now-playing buttons, health actions.

**Review checklist**

- [x] SwiftUI views mostly render state and send intents.
- [x] View models exist only for screens with real workflow state.
- [x] Business rules live in focused use-case services.
- [x] Repositories provide scoped data access.
- [x] `PlaybackController` coordinates playback instead of owning every concern.
- [x] CarPlay and SwiftUI share presentation builders and use cases.
- [x] Duplicate formatting and state derivation are removed.
- [x] Full test suite passes.

**Commit criteria**

- All checklist items satisfied.
- This document updated to mark the refactor complete.

</details>

---

## Recommended Sequence (Historical)

All checkpoints below are complete.

1. Add shared presentation models through finish-work checkpoints 15–20.
2. See archive sections for the original 14-checkpoint sequence and the 15–20 finish work.

---

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

---

## Completed Checkpoints (Archive)

The original 14 checkpoints are complete or mostly complete. They are preserved
here as a record of what was planned and delivered.

<details>
<summary>Checkpoints 1–14 (original plan)</summary>

### Checkpoint 1: Add Shared Presentation Models — Done

Created `PlaylistSummaryPresentation`, `TrackSummaryPresentation`,
`NowPlayingPresentation`, `TrackHealthPresentation`, `PlaybackControlsPresentation`.
Replaced call sites in Dashboard, selection, now-playing, and CarPlay snapshot.

### Checkpoint 2: Extract Playlist Presentation Builder — Done

Created `PlaylistPresentationBuilder`. iOS and CarPlay playlist lists share ordering,
counts, and artwork selection.

### Checkpoint 3: Fix Repository Scalability — Mostly Done

Added predicate-based repository APIs and `firstValueDictionary`. Fetch-all call
sites in views remain (see Checkpoint 18).

### Checkpoint 4: Extract Track Health Use Case — Done

Created `TrackHealthActionService`. iOS, CarPlay, and History delegate track-health
mutations.

### Checkpoint 5: Extract Playback Session Evaluation — Done

Created `PlaybackSessionEvaluationService`. Skip, playthrough, and eviction
evaluation extracted from `PlaybackController`.

### Checkpoint 6: Extract Queue And Mode Coordination — Done

Created `PlaybackQueueCoordinator` and `PlaybackModeCoordinator`.

### Checkpoint 7: Thin PlaybackController — Partial

Controller delegates to extracted services but remains large. See Checkpoint 17.

### Checkpoint 8: Extract App Startup View Model — Done

Created `AppStartupViewModel`. `AppRouter` handles routing only.

### Checkpoint 9: Split AppRouter And Shell Views — Mostly Done

Shell types in `Overplay/App/Shell/AppShell.swift`. Shared now-playing components
in `NowPlayingComponents.swift`. File splits deferred (see Checkpoint 19).

### Checkpoint 10: Introduce Screen View Models — Done

Created `PlaylistSelectionViewModel`, `SearchMusicViewModel`,
`PlaylistManagementViewModel`, `SettingsViewModel`, `HistoryViewModel` with tests.

### Checkpoint 11: Make CarPlay A Presentation Adapter — Partial

Playlists and track-health actions shared. Track summaries and now-playing
presentation still diverge. See Checkpoints 15–16.

### Checkpoint 12: Clean Up Remote Command Service — Done

Lifecycle API: `activate`, `update`, `deactivate`, `syncPlaybackModes`. Target
tokens stored and removed on deactivation.

### Checkpoint 13: Add MusicKit Playlist Pagination — Done

`MusicLibraryPagination` and `MusicKitLibraryPlaylistFetcher` page through library
playlists. Tests use fake paged responses.

### Checkpoint 14: Final Naming And Organization Cleanup — Partial

`EvictionHistoryView` renamed to `HistoryView`. `PlaylistManagementView` moved out
of `DashboardView`. Other cleanup deferred (see Checkpoint 19).

</details>

---

## Document Review

This plan intentionally starts with shared presentation and use-case seams
rather than a full MVVM conversion. That order kept risk lower because it
removed duplication and business logic from overloaded services before view
models were introduced.

The refactor completed in two phases: checkpoints 1–14 established the
architecture, and checkpoints 15–20 finished CarPlay parity, controller slimming,
repository scoping, and file organization. Manual smoke tests on device (playback,
CarPlay, lock-screen controls) remain recommended after major playback changes.
