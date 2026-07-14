# Track Identity and Skip Counting Fix Plan

This plan fixes the failure modes around track identification and skip
counting found in the 2026-07-14 codebase analysis. It follows the same
conventions as `TODO.md`: small committable steps, each leaving the app
buildable with tests passing, ordered so later steps can rely on earlier
ones.

Root causes being addressed:

1. Track identity is keyed on raw MusicKit ID strings. Apple Music has two
   ID domains (catalog vs. library) and the app conflates them instead of
   bridging them, producing duplicate `TrackRecord`s, duplicate playlist
   rows, and split skip counts.
2. Skip/playthrough evaluation depends on a 1-second foreground poll plus a
   fragile in-memory `TrackPlaySession` that is recreated whenever identity
   resolution flaps. Missed polls (app suspension) or identity flaps become
   phantom skips, double counts, or missed playthroughs.

Ordering rationale: identity fixes come first (Steps 1-2) because session
evaluation attributes counts through identity resolution; session
correctness next (Steps 3-5); transition races (Step 6); hardening
(Step 7); cleanup (Step 8); performance (Step 9); refinements (Step 10);
documentation and final verification last.

## Step 0 - Land Current Working-Tree Change

The working tree has an uncommitted, coherent change: stale evaluation
outcomes now refresh the active playlist snapshot without replacing the
displayed track (`PlaybackController.applyEvaluationOutcome`,
`evaluationOutcomeAffectsActivePlaylist`, plus a test).

- Run the test suite.
- Commit as its own change before starting this plan.

Verification:

- App target builds.
- Unit tests pass.

## Step 1 - Capture Distinct Catalog and Library Identity at the Source

Problem: every `TrackSnapshot` construction site sets
`catalogID = libraryID = track.id.rawValue`
(`AppleMusicPlaylistSourceSync.snapshot`, `PlaylistSyncService.snapshot`,
`PlaybackTrackResolver.snapshot(from:)` x2), and
`PlaylistMutationService.recordSuccessfulManualAdd` stores the catalog
search ID in both fields. The two-field OR-match in
`TrackRecordRepository.track(catalogID:libraryID:)` can therefore never
bridge the two domains, and the same song enters the store twice.

Changes:

- Add a `MusicTrackIdentity` helper that extracts
  `(catalogID: String?, libraryID: String?)` from a MusicKit `Track` /
  `Song`:
  - IDs beginning with `i.` are library IDs; other numeric IDs are catalog
    IDs.
  - For library tracks, best-effort decode the catalog ID from
    `playParameters` (encode `PlayParameters` to JSON, read `catalogId`).
    Treat this as optional enrichment; missing is fine.
- Update all snapshot construction sites to populate `catalogID` and
  `libraryID` distinctly, leaving the unknown domain `nil`. Never mirror.
- `recordSuccessfulManualAdd`: store `catalogID: result.id`,
  `libraryID: nil`.
- `TrackRecordRepository.upsertWithResult`:
  - Stop the `snapshot.catalogID ?? snapshot.id` /
    `snapshot.libraryID ?? snapshot.id` mirroring.
  - Change ID assignment to fill-only semantics: set `catalogID` /
    `libraryID` when the stored value is `nil`, never overwrite a non-nil
    stored ID with `nil`, and only replace a differing non-nil ID when the
    incoming snapshot carries the same domain (heal, don't clobber).
- Extend `PlaybackQueueBuilder.musicItemIDs(for:)` to also include the
  `playParameters` catalog ID decoded from `musicKitPlaybackData`, so
  runtime identity matching bridges domains for records that already exist
  (they have mirrored IDs but valid playback data). This also removes the
  identity-flap risk for tracks appended to the live queue, whose aliases
  are never proactively recorded.

Tests:

- `MusicTrackIdentity` extraction from fixture `playParameters` JSON and
  from bare catalog/library IDs.
- Upsert bridging: insert a record via catalog-only snapshot (manual add),
  then upsert a library-domain snapshot for the same song carrying the
  catalog ID → same record updated, IDs merged, no duplicate.
- Fill-only semantics: a later snapshot with `nil` catalog ID does not
  erase a stored catalog ID.
- `musicItemIDs(for:)` includes the playback-data catalog ID.

Verification:

- App target builds; unit tests pass.
- Manual: search-add a track, sync the playlist, confirm a single row.

## Step 2 - Song-Identity Merge Pass and Stat-Preserving Dedup

Problem: existing stores already contain duplicate `TrackRecord`s for the
same song (catalog vs. library keyed), and CloudKit multi-device races can
insert parallel records because SwiftData+CloudKit cannot enforce unique
constraints. `PlaylistItemRepository.removeDuplicateItems` only collapses
same-`(playlistID, trackID)` items and deletes the newer item's counts
instead of merging them.

Changes:

- Add `TrackIdentityMergeService`:
  - Group all `TrackRecord`s by shared identity using union-find over each
    record's `musicItemIDs(for:)` set (post-Step 1 this includes the
    playback-data catalog ID, so legacy mirrored records bridge).
  - For each group, pick the canonical record (oldest `createdAt`,
    tie-break by UUID) and merge the others into it:
    - Fill missing `catalogID`/`libraryID`/`musicKitPlaybackData`/artwork
      fields from duplicates.
    - Repoint every `PlaylistItemRecord.trackID` from duplicate to
      canonical.
    - Repoint `HistoryEvent.trackID` references.
    - Delete the duplicate `TrackRecord`s.
  - When repointing creates two items with the same
    `(playlistID, trackID)`, merge them: **sum** `skipCount` and
    `playthroughCount`; keep earliest `createdAt`; keep latest
    `lastPlayedAt`, `lastSkippedAt`, `lastSeenInPlaylistAt`; take
    eviction/protected state from the most recently `updatedAt` item; keep
    a non-nil `musicPlaylistEntryID` if either has one.
  - Rekey device-local stores for merged local track IDs:
    `PlaybackOrderStore` ordered IDs (replace + dedupe),
    `PlaybackIdentityStore` alias keys, `LocalPlaybackStateStore`
    `localTrackID`.
  - Idempotent; single `context.save()`; log a merge summary through
    `TrackMetadataDiagnostics`.
- Rewrite `removeDuplicateItems` merging to the same stat-summing rules
  (or delegate to the merge service) so CloudKit item duplicates stop
  losing counts.
- Invoke the merge pass:
  - Once at startup (in `AppStartupViewModel`, before playback restore).
  - After each successful `PlaylistSyncService.syncPlaylist`.

Tests:

- Two records for one song (catalog-keyed and library-keyed with playback
  data) merge to one; playlist items repointed; counts summed; history
  repointed; order store rekeyed without duplicates.
- Eviction state survives via most-recent-update rule.
- Idempotency: running the pass twice changes nothing the second time.
- `removeDuplicateItems` sums counts instead of dropping them.

Verification:

- App target builds; unit tests pass.
- Manual: a store with known duplicate rows heals on next launch/sync and
  the surviving row shows combined counts.

## Step 3 - Staleness-Aware Session Evaluation (Suspension Phantom Skips)

Problem: `ApplicationMusicPlayer` plays out-of-process, so music continues
while Overplay is suspended and the 1-second monitor stops. On resume,
`refresh()` evaluates the outgoing session with `lastObservedPlaybackTime`
frozen at suspension time and counts a phantom skip for a track that
played through. There is no foreground reconciliation anywhere.

Changes:

- Add `lastObservedAt: Date` to `TrackPlaySession`; set it in
  `PlaybackSessionSupport.makeSession` and update it in
  `updateObservedProgress`.
- In `PlaybackSessionEvaluationService.evaluateActiveSession`, accept
  `now: Date = .now` and compute the observation age at evaluation time.
  If age exceeds a staleness threshold (constant, ~5 seconds — several
  missed polls), the session cannot distinguish skip from natural
  completion:
  - If observed progress had already reached the playthrough threshold,
    still count the playthrough (it was genuinely observed).
  - Otherwise count **nothing** and log a `skipIgnored` history event with
    message "Stale observation" (unknown must never become a skip).
- Thread the staleness decision into `EvictionEngine.evaluateSkip` as an
  explicit parameter (engine stays a pure counting rule; the service
  decides staleness).
- No scenePhase machinery is required: the first post-resume evaluation is
  exactly the one the staleness check guards. Tracks that elapsed entirely
  during suspension remain unevaluated by design (no data, no count).

Tests:

- Stale session, progress 30% → no skip counted, `skipIgnored` logged.
- Stale session, progress 95% → playthrough counted.
- Fresh session, ≥10 s listened, <50% → skip counted (unchanged).

Verification:

- App target builds; unit tests pass.
- Manual: start a track, lock the phone, let 2-3 tracks play, unlock —
  history shows no new skips for the suspended interval.

## Step 4 - Restore Sessions Are Display-Only

Problem: `PlaybackRestorationService.displayRestoreState` seeds
`activeSession` with `hasEvaluated: false` from persisted state that can
be days old. The next playback start evaluates it via
`evaluateOutgoingSessionBeforePlaybackReplacement`: paused at <50% last
session → phantom skip on relaunch; closed right after a track finished →
double playthrough.

Changes:

- `displayRestoreState` builds its session with `hasEvaluated: true`.
- Audit `restoreLocalPlaybackState` (full restore): it does not seed a
  session, and `refresh()` bootstraps one at the restored position — note
  that Step 10's listening-time accounting is what prevents a
  restored-position bootstrap from satisfying the minimum-listening check.

Tests:

- Display-restored session is never evaluated: after
  `restoreLocalPlaybackDisplay`, starting a different playlist produces no
  skip/playthrough event for the restored track.
- Update `PlaybackControllerDisplayRestoreTests` fixtures accordingly.

Verification:

- App target builds; unit tests pass.
- Manual: pause mid-track, force-quit, relaunch, play another playlist —
  history gains no event for the restored track.

## Step 5 - Explicit Natural-Completion Detection and End-of-Queue Repeat

Problem: `naturalCompletion: true` is only passed in the queue-ended
branch of `refresh()`, which is unreachable because
`resolvedCurrentPlaybackIdentity` falls back through
`activeQueueCurrentEntry` → `activeSession` → `currentTrack` and never
returns nil during playback. Mid-queue natural completions are evaluated
as manual transitions (playthrough only because the last poll happened to
catch ≥90%), and the spec's end-of-playlist reshuffle-repeat never fires
from natural completion — playback just stops.

Changes:

- Add `PlaybackSessionEvaluationService.inferredNaturalCompletion(session:)`:
  true when `lastObservedPlaybackTime` is within
  `max(2 × poll interval, 3 s)` of `durationSeconds` (or progress ≥ ~98%).
  Inside `evaluateActiveSession`, upgrade `naturalCompletion` when
  inferred. This makes mid-queue auto-advance evaluation explicit rather
  than an accident of the last poll.
- Detect queue end directly in `refresh()` instead of via nil identity:
  when `player.queue.currentEntry == nil` (or playback status is
  `.stopped`) while `activeQueueEntries` is non-empty and the outgoing
  session's observed position is near its duration:
  - Evaluate the outgoing session (natural completion inferred).
  - Call `handleQueueEnded` to reshuffle, rebuild the queue, and restart
    per the spec's repeat behavior.
  - Guard restart behind the near-end check so an external Stop (position
    far from the end) does not trigger a surprise restart.
- Add a low-frequency diagnostics log of `playbackStatus` +
  `currentEntry` presence at queue end to confirm actual MusicKit
  end-state on-device (its behavior here is not documented).

Tests:

- `inferredNaturalCompletion` boundary tests (near end true, mid-track
  false, nil duration false).
- Evaluation upgrade: session at duration-1 s evaluated with
  `naturalCompletion: false` still counts a playthrough via inference.
- Queue-end detection decision extracted as a pure function and tested
  (had entries + nil current entry + near end → restart; far from end →
  no restart).

Verification:

- App target builds; unit tests pass.
- Manual: let the last track of a small playlist finish naturally —
  playback restarts with a fresh shuffle and the last track is not in the
  top five; stopping playback from the Music app mid-track does not
  restart it.

## Step 6 - Fix Next/Previous Index Race and Pending-Advance Clearing

Problem: `try await player.skipToNextEntry()` is a suspension point; a
monitor tick can land inside it, observe the advanced player entry, and
move `activeQueueIndex` to N+1 — then `next()` resumes and blindly
advances by one more to N+2. `pendingQueueAdvance` then pins the wrong
identity for up to 2 s (it only clears on exact match or timeout),
producing wrong Now Playing display, bogus `skipIgnored` history for a
track that never played, session churn, and wrong persisted restore
state. `previous()` at index 0 nils the index and temporarily breaks
`canControlPlayback`.

Changes:

- Add an `isPerformingTransition` flag on `PlaybackController`. While set,
  `refresh()` only updates `elapsedSeconds`/`isPlaying`/Now Playing
  metadata and skips identity resolution, session mutation, and index
  updates. Set it for the duration of `next()`/`previous()`/queue
  rebuilds; clear in a `defer`.
- Replace blind `advanceActiveQueueIndex(by:)` reconciliation:
  - Capture the pre-transition index before awaiting MusicKit.
  - After the await, if `player.queue.currentEntry` maps to a realized
    entry, set the index from it; otherwise set
    `preTransitionIndex ± 1` (bounded).
  - In `previous()` at index 0, keep index 0 (MusicKit restarts the
    track); never nil the index on an in-bounds transition.
- Rework the pending-advance policy to know where the transition came
  from. Store `fromLocalTrackID` alongside the pending target and decide:
  - Confirmed entry == pending target → clear (arrived).
  - Confirmed entry == from-track → keep (still propagating).
  - Confirmed entry is anything else → clear (player went elsewhere; do
    not pin a wrong identity).
  - Extract this as a pure `PlaybackPendingAdvancePolicy` for direct
    testing; keep the 2 s timeout as a backstop.

Tests:

- Pending-advance policy: arrived / propagating / diverged / timeout.
- Index reconciliation from realized entry vs. offset fallback.
- Simulated interleave: index moved externally between evaluate and
  reconcile does not double-advance (drive via the pure helpers).

Verification:

- App target builds; unit tests pass.
- Manual: rapid repeated Next presses keep Now Playing, the playlist
  current-row highlight, and lock-screen metadata in agreement; history
  gains no `skipIgnored` entries for tracks that never played.

## Step 7 - Harden Identity-Change Detection Against Domain Flips

Problem: `playbackIdentityDidChange` falls back to comparing raw music
item IDs when either side lacks a local track ID. A catalog↔library
report flip for the same track registers as a track change and triggers a
mid-play evaluation of the still-playing track — a phantom skip once ≥10 s
in and <50% through.

Changes:

- Before declaring a change on a raw-ID mismatch, check whether the new
  music item ID belongs to the current track's known ID set
  (`musicItemIDs(for:)` of the resolved current record, which after
  Step 1 includes both domains). Same set → not a change; record the ID
  as an alias.
- Implement as a pure function taking the old identity, new identity, and
  the current track's known ID set so it is directly testable; call it
  from `refresh()` where context is available.

Tests:

- Same track, catalog↔library flip → no change detected, alias recorded.
- Genuinely different track → change detected.
- Missing local IDs on both sides with disjoint ID sets → change detected.

Verification:

- App target builds; unit tests pass.
- Manual: extended playback session produces no "suppressed stale
  evaluation outcome" or spurious mid-track skip diagnostics.

## Step 8 - Remove Dead Machinery and Resolve the Skip-Reset Contradiction

Problem: several vestigial mechanisms complicate the exact code paths
being fixed. `pendingModeQueueRebuild` is never set non-nil, so
`stagePendingModeQueueRebuild`, `applyPendingModeQueueRebuild`, and the
`isModeQueueRebuildPending` parameter of `PlaybackIdentityFallbackPolicy`
are dead. `skipForwardIntent` always returns `.standard`.
`playthroughResetsSkipCount` (default `true`) is dead — the engine never
resets skips — and its name/default contradict both the spec and actual
behavior.

Changes:

- Delete `PendingModeQueueRebuild`, the property, `stage…`/`apply…`
  methods, and the fallback-policy parameter; update policy tests.
- Audit `skipForwardIntent` callers; delete the controller method, the
  service stub, and `PlaybackSkipForwardIntent` if the UI renders nothing
  from it (or reimplement for real if a caller depends on a meaningful
  intent — decide during the step).
- Remove `playthroughResetsSkipCount` from `OverplaySettings`,
  `playthroughWouldResetSkipCount` from the evaluation service, the
  threading through `NowPlayingPresentation`/`NowPlayingPresentationFactory`,
  and any Settings UI toggle. Behavior stays: playthroughs never reset
  skip counts (spec).
- Note: removing a SwiftData settings field is a lightweight migration;
  verify CloudKit tolerance on a dev container before committing.

Tests:

- Update/remove affected tests (`PlaybackIdentityFallbackPolicyTests`,
  presentation tests, settings tests).

Verification:

- App target builds; unit tests pass; no remaining references.

## Step 9 - Move Heavy Per-Tick Work Off the Refresh Path

Problem: every 1-second `refresh()` tick during playback calls
`reconcileCurrentPlaybackOrder` → `reconcileStoredOrder`, which runs
`removeDuplicateItems` (full item-table scan, grouping, possible save)
and unconditionally rebuilds the active playlist snapshot (full
items+tracks refetch). This is a performance and SwiftData-contention
problem and multiplies exposure to the race windows fixed above.

Changes:

- Remove `reconcileCurrentPlaybackOrder` from the per-tick path. Invoke
  `reconcileStoredOrder` on the events that can actually change
  membership/order: playback start, sync completion for the current
  playlist, eviction/restore/promotion/manual-add mutations, and
  switching away from a playlist (spec requirement).
- Inside `reconcileStoredOrder`, only call `rebuildActivePlaylistSnapshot`
  when the reconciled order actually changed (it currently rebuilds every
  call).
- Duplicate-item cleanup moves entirely to the Step 2 merge pass
  (startup + post-sync); it leaves the playback tick.
- Keep the cheap `updateActivePlaylistSnapshotCurrentRow` per tick.

Tests:

- Order reconciliation still appends synced additions to the live order
  (existing tests should cover; extend if trigger wiring is extracted).

Verification:

- App target builds; unit tests pass.
- Manual: CPU/energy during playback visibly drops; playlist rows still
  update after sync, eviction, and promotion while playing.

## Step 10 - Count Listening Time, Not Playback Position

Problem: the minimum-listening check uses playback position
(`session.lastObservedPlaybackTime >= minimumSkipListeningSeconds`).
Seeking forward then skipping, or bootstrapping a session at a restored
mid-track position, satisfies "listened for at least N seconds" without
any listening. The spec wording is "listened for".

Changes:

- Add `listenedSeconds: Double` to `TrackPlaySession`, accumulated in
  `updateObservedProgress`: add `newElapsed − lastObserved` only when the
  delta is within `0…(poll interval × 1.5)` (seeks and stale jumps add
  nothing); bootstrapped sessions start at 0.
- Skip decision: minimum-listening check uses `listenedSeconds`; the
  skip-threshold percentage check keeps using position/duration.
- This also closes the Step 4 residual: a session bootstrapped at a
  restored position cannot immediately satisfy the minimum-listening
  requirement.

Tests:

- Seek to 60%, back to 20%, skip → listened time governs, not position.
- Bootstrap at 40% then immediate skip → ignored (listened ≈ 0).
- Normal listening across polls accumulates correctly.

Verification:

- App target builds; unit tests pass.

## Step 11 - Update Spec and Audit Documents

Changes:

- `OVERPLAY_DESIGN_SPEC.md`:
  - Document the dual-domain identity model (distinct catalog/library IDs,
    fill-only merging, sync-time identity merge pass).
  - Document the staleness rule: an unobserved interval never counts a
    skip; observed playthrough threshold still counts.
  - Document natural-completion inference and end-of-queue repeat
    triggering.
  - Record the product decision that switching playlists evaluates the
    outgoing track (current behavior, kept deliberately).
  - Document listening-time (not position) for the minimum-skip check.
- `OVERPLAY_SPEC_IMPLEMENTATION_AUDIT.md`: mark resolved items; note the
  removed `playthroughResetsSkipCount` setting.

Verification:

- Docs match implemented behavior; no code changes in this step.

## Step 12 - Full Verification Pass

- Run the complete unit test suite.
- Manual device checklist:
  1. Skip at <10 s → no skip counted.
  2. Skip at ~30% → skip counted once.
  3. Skip at ~70% → neither skip nor playthrough.
  4. Natural completion → playthrough counted once.
  5. Lock the phone, let several tracks play, unlock → no phantom skips;
     no missing-track misattribution.
  6. Pause mid-track, force-quit, relaunch, play another playlist → no
     phantom event for the restored track.
  7. Manual-add a searched track, then sync → single row, counts intact.
  8. Promote a triage track, then sync both playlists → single OTP row.
  9. Rapid Next presses → UI, lock screen, and CarPlay agree; no bogus
     history events.
  10. Last track finishes naturally → reshuffled repeat starts; recently
      played track not in the new top five.
  11. Evict the current track → advances, remote removal attempted per
      policy.
  12. Two devices on one account: play independently; counts converge
      without duplicate rows.

Verification:

- All checklist items pass on device (or documented as blocked with
  reason).
