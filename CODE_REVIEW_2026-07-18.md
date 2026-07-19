# Overplay Full Code Review — 2026-07-18

Working document. Written incrementally so the review can be resumed if the
session ends. Each chunk is marked TODO / IN PROGRESS / DONE. Findings carry
IDs (BUG-n, PERF-n, SURF-n for cross-surface, DOC-n) with file:line refs and
a severity (high / medium / low). Resume instructions: pick the first chunk
not marked DONE, read the listed files, append findings, update the status.

Baseline: main @ 23236c1 plus uncommitted working-tree changes:
- PlaylistSelectionView @Query reduction (this session, verified, full suite green)
- App icon SVG redesign (user's, out of scope)
- NewModelRepositoryTests message expectation update (this session)

## Chunk status

1. DONE — Inventory (114 app files / ~18.4k lines, 56 test files; biggest:
   AlbumArtworkTheme 2118, PlaybackController 2095, CarPlayCoordinator 536,
   PlaylistSyncService 513)
2. DONE — README accuracy pass. README is recent (consolidated in cb97dce)
   and structurally accurate. Fixed DOC-1. Behavior claims (cross-surface
   parity, no-phantom-skips) re-verified in chunk 11 after the deep review.
3. DONE — Playback core: PlaybackController.swift read in full (see findings)
4. DONE — Skip/playthrough capture (evaluation service, EvictionEngine,
   session support, restoration, local state store, backgrounding)
5. DONE — Queue/order machinery (orchestrator, coordinator, materializer,
   end policy, identity store, order engine/coordinator)
6. DONE — Cross-surface: RemoteCommandService, CarPlayCoordinator,
   NowPlayingMetadataService, AppRuntime/AppStartupViewModel wiring
7. DONE — Sync: PlaylistSyncService, PeriodicPlaylistSyncService (EvictionEngine
   covered in chunk 4; identity merge + mutation service in chunk 10)
8. DONE — Persistence/repositories (Playlist/Settings/Event; Item/Track read
   earlier). Clean: indexed predicates, fetchLimit 1, includePendingChanges,
   explicit saves. No N+1 beyond items(forPlaylistIDs:) loop (few playlists).
9. DONE — Views + ViewModels perf pass
10. DONE — Remaining services (TrackIdentityMergeService: union-find +
    yields + store rekeys, solid; PlaylistMutationService: explicit saves,
    failure history events, matches known spec deviations;
    artwork/theme pipeline: actor-isolated, detached pixel work — good)
11. DONE — Synthesis below
12. DONE — Offline / delivery-failure resilience (added 2026-07-18 after a
    field report: two incidents of playback dying while driving through
    low-connectivity areas, with the Music app failing alongside)

## Findings

(appended per chunk below)

### Chunk 2 — README

- DOC-1 (low, FIXED): README pointed at `Config/*.xcconfig`; actual location
  is `Overplay/Config/*.xcconfig`. Corrected all three references.

### Chunk 3 — PlaybackController

- PERF-1 (medium, FIXED 2026-07-19): the 1 Hz monitor ran for the rest of
  the app's life once playback started, executing 3-4 SwiftData fetches per
  tick (settings + current TrackRecord twice) even while paused for hours.
  Now: (1) PlaybackMonitorIdlePolicy suspends the monitor after 5 minutes
  of non-playing, non-stalled ticks — every play path already calls
  startMonitoring, which resumes it; stall episodes keep it alive so
  auto-recovery keeps ticking. (2) The settings row is cached as a live
  model reference (singleton object — value changes are reflected; replaced
  only if deleted, e.g. database reset). (3) The current track's known
  music item IDs are cached per local track ID, invalidated by
  bumpPlaybackItemMetadataVersion (every metadata change) and never caching
  misses, covering both currentTrackKnownMusicItemIDs and
  recordTrustedRuntimeAlias. Steady-state playing tick now does zero
  repeat fetches; idle does nothing at all. Tests:
  PlaybackMonitorIdlePolicyTests.
- PERF-2 (low-medium): `rebuildActivePlaylistSnapshot`
  (PlaybackController.swift:2055) fetches ALL items + ALL tracks of the
  current playlist on the main context. Called on every track action AND on
  every counted skip/playthrough via applyEvaluationOutcome (:1374). On a
  large playlist this is a per-transition full-playlist fetch. Acceptable per
  user action; consider reusing snapshot + patching the affected row for
  evaluation outcomes.
- BUG-1 (candidate, needs chunk-4 confirmation):
  `removeEvictedItemFromPlaylist` (PlaybackController.swift:1300) resolves
  the remote-removal ID as `currentTrack?.id` FIRST, falling back to the
  evicted item's own catalog/library ID. If an evaluation outcome ever
  evicts an item that is not the displayed track (stale-outcome path is
  explicitly possible — see the "suppressed stale evaluation outcome" log at
  :1358, and :1341 calls removeEvicted... without any matching check), the
  app would ask Apple Music to delete the WRONG track (the currently
  displayed one) from the playlist. Safer: derive the ID from item.trackID
  always; use currentTrack only as a last resort when item lookup fails AND
  item is verified current. Severity high if evaluation can still evict —
  verify `evictedDuringEvaluation` reachability in
  PlaybackSessionEvaluationService.
- NOTE: next()/previous()/togglePlayPause/evict/promote all evaluate the
  outgoing session BEFORE the player transition, with witnessed-listening
  fallbacks — good; cross-surface parity depends on remote commands routing
  here (chunk 6).
- NOTE: shuffleEnabled/repeatMode are hardcoded stubs (false/.none) with
  playbackModeVersion observation hooks — intentional (app-managed order),
  not a bug.

### Chunk 4 — Skip/playthrough capture

Verdict on capture correctness: SOLID. The core rules hold:
- Skips gate on witnessed listening (`session.listenedSeconds >=
  minimumSkipListeningSeconds`, EvictionEngine.swift:97), accumulated only
  from ≤1.5s position deltas (PlaybackSessionEvaluationService.swift:51-63),
  so seeks and suspended playback contribute nothing.
- Stale observations (>5s old — i.e., missed polls/suspension) can never
  count as skips (EvictionEngine.swift:76-94, "unknown must never count").
- Natural completion within a 3s poll-gap tolerance counts as playthrough,
  not skip. Double-count prevented by session.hasEvaluated.
- Relaunch restore builds the session with hasEvaluated: true
  (PlaybackRestorationService.swift:41-48) — relaunches cannot fabricate
  counts. Confirmed by design comment and code.

Findings:
- BUG-1 RESOLVED→CLEANUP-1 (low): `EvictionEngine.evaluateSkip`/
  `countPlaythrough` never set `evictedAt` since the auto-eviction removal
  (23236c1), so `EvaluationOutcome.evictedDuringEvaluation` is ALWAYS false.
  Dead code that should go: the evict branches in
  PlaybackController.applyEvaluationOutcome (:1369-1373) and
  evaluateActiveSession (:1341-1343), plus the flag itself. The hazardous
  `currentTrack?.id`-first remote-delete ID resolution in
  removeEvictedItemFromPlaylist (:1300) is currently only reachable from
  evictCurrent (item IS current), so no live bug — but reorder to
  item-derived catalog/library ID first as a safety margin when touching it.
- BUG-2 (low, product decision): playthroughs are position-based
  (`progressPercentage` from lastObservedPlaybackTime), so SEEKING past the
  playthrough threshold counts a playthrough with zero witnessed listening
  (evaluatePlaythroughIfNeeded, PlaybackSessionEvaluationService.swift:224).
  Inconsistent with the hardened witnessed-listening skip rule (Step 10).
  If intended ("reached X%"), document it in the spec; otherwise gate on
  listenedSeconds too.
- BUG-3 (low, UI-only): the Now Playing progress-phase hint uses
  `skipWouldCount` with raw elapsed position
  (NowPlayingPresentation.swift:98), while the engine uses witnessed
  listening. After a seek, the danger/safe tint can disagree with what the
  engine will actually count.
- SURF-1 (medium, by-design limitation, must be documented): playback that
  happens ENTIRELY while Overplay is suspended is not counted at all —
  no skips (correct, README's no-phantom-skips claim holds) but also NO
  playthroughs. ApplicationMusicPlayer plays out-of-process; there is no
  scenePhase/background-task handling anywhere (grep confirms), no
  MusicKit queue observation while suspended, and the staleness rule
  deliberately discards unwitnessed transitions. Answer to the review
  question "are skips/playthroughs captured when backgrounded": skips are
  never fabricated, but playthroughs completed while suspended are LOST by
  design. README wording is accurate but one-sided; consider stating the
  playthrough side explicitly.
  RESOLVED (2026-07-19, implemented): suspended playthroughs are recovered
  via BGAppRefresh wakes aimed at the playthrough-threshold crossing of the
  current track, plus point/continuity reconciliation on every wake. Skips
  stay unwitnessed-never-counted. Full design + implementation notes under
  synthesis item 4. On-device verification of MusicKit state readability in
  background wakes still pending.
- PERF-3 (low): PlaybackSessionSupport.resolvePlaylistItem's fallback
  (:62-63) fetches ALL items + ALL tracks of the playlist; only hit when
  scoped/current-item resolution fails, so rarely hot. Fine for now.

### Chunk 5 — Queue and order machinery

Clean layer: pure functions, deterministic reconciliation, dedup everywhere.
`reshuffledOrder` re-inserts the just-played track at index 5 — matches the
"recently played not in new top five" checklist item. `moveTrackIDToBottom`
maintains both scope orders symmetrically. `reconciledTransitionIndex`
prefers the player-reported entry and never advances from a concurrently
moved index. No logic bugs found.

- PERF-4 (medium, FIXED 2026-07-19): `PlaybackQueueCoordinator
  .localTrackID(matching:)` falls back to fetching ALL TrackRecords when
  the indexed lookup misses, and with an unresolvable track playing the
  1 Hz refresh re-ran that full scan every second. Now
  PlaybackController.localTrackID negative-caches misses per musicItemID
  (`unresolvableMusicItemIDs`), cleared by bumpPlaybackItemMetadataVersion
  (every metadata change/track transition), reconcileStoredOrder (sync and
  membership changes can heal a miss), and database reset — one scan per
  track episode instead of one per second.
- NOTE: PlaybackIdentityStore decodes the full JSON alias dictionary from
  UserDefaults on every read; hot-path reads are mostly short-circuited
  earlier (recordTrustedRuntimeAlias's track-record check), so this rides on
  PERF-1's caching fix.

### Chunk 6 — Cross-surface parity (app / CarPlay / Lock Screen / Control Center)

STRUCTURAL PARITY: CONFIRMED. Every surface funnels into the one shared
PlaybackController on the MainActor:
- Lock Screen + Control Center + headset: MPRemoteCommandCenter handlers in
  RemoteCommandService route play→playCurrentOrDefault, pause→pause,
  toggle→togglePlayPause/performPrimaryPlaybackAction, next→next(settings:),
  previous→previous, shuffle→reshuffleCurrentPlaylist. next() evaluates the
  outgoing session before the transition, so a Lock Screen skip counts
  identically to an in-app skip.
- CarPlay: transport buttons are CPNowPlayingTemplate → the SAME
  MPRemoteCommandCenter handlers; custom buttons (evict/promote/restore,
  shuffle) call playbackController.evictCurrent / promoteCurrent /
  restoreCurrent / remoteCommandService.applyShuffleModeCommand. List play
  goes through playbackController.playPlaylist. No duplicated logic found.
- Every mutation path reachable from CarPlay/remote saves explicitly
  (TrackActionService.* all `try context.save()`; session evaluation saves)
  — important because CarPlay runs on a fresh ModelContext where autosave
  is off.

Findings:
- SURF-2 (medium, needs on-device confirmation): counting from Lock
  Screen/CarPlay only works while the Overplay PROCESS is alive.
  MPRemoteCommand handlers cannot run while suspended, and Overplay hosts no
  audio session (ApplicationMusicPlayer plays out-of-process), so once iOS
  suspends the app, Lock Screen next presses are handled by the system/Music
  directly; on resume the transition is unwitnessed → deliberately ignored
  (no skip, no playthrough). Same root cause as SURF-1. Whether iOS keeps
  Overplay's handlers reachable while backgrounded-but-not-suspended is
  device-verifiable only (TODO.md checklist already covers it).
  RESOLVED (2026-07-19, implemented): same reconciliation implementation as
  SURF-1 (see synthesis item 4) — Lock Screen presses while suspended still
  bypass live counting, but completed tracks in the suspended span are
  recovered when provable. Note the driving case may largely be covered
  already: while Overplay's CarPlay scene is on the car display the process
  is foreground on that screen and the 1 Hz monitor runs — the CarPlay
  device check on the TODO.md checklist should confirm this.
- BUG-4 (low): after CarPlay disconnects, RemoteCommandService keeps the
  CarPlay-created ModelContext forever (CarPlayCoordinator.connect calls
  activate→update with its own context (:33); disconnect (:48) never
  re-points it at the main context). Works today because every downstream
  path refetches by ID and saves explicitly, but Lock Screen mutations then
  persist through an orphaned secondary context and reach the UI only via
  cross-context merge. Cheap fix: on disconnect, update(playbackController:
  context:) back to the main context (or have AppStartupViewModel re-assert
  on foreground).
- PERF-5 (low-medium): CarPlayCoordinator.observePlaybackController
  (:292-299) tracks elapsedSeconds/durationSeconds, which change EVERY
  second, but the button signature (trackID, role, skipCount, protected,
  evicted) doesn't use them. Each tick re-runs currentSettings() (SwiftData
  fetch) + carPlayButtonSignature (displayed* context fetches) just to
  compare an unchanged signature. Drop elapsed/duration from the tracked
  set.
- NOTE (already in TODO.md): NowPlayingMetadataService publishes
  title/artist/album/duration/elapsed/rate but NOT artwork — known gap,
  listed under "Now Playing Metadata".
- NOTE: refreshLibraryLists rebuilds visible CarPlay sections with per-row
  TrackRecord fetches (isCurrentTrack), but only runs when the button
  signature actually changed. Acceptable.

### Chunk 7 — Sync services

PeriodicPlaylistSyncService is well designed: 30-min cadence + freshness
gate, current/selected playlist prioritized, 500ms inter-playlist pacing,
gated once-per-cycle identity merge, cancellation checks. No issues.

- DOC-2 (medium, FIXED 2026-07-19): remote REMOVALS are not reconciled —
  PlaylistSyncService.reconcile only upserts. README was corrected during
  the review; the DESIGN SPEC self-contradiction is now resolved: the
  PlaylistSyncService component summary matches "Removals from Apple Music"
  (leave items in place, history preserved, no local removal state) and
  documents the lastSeenInPlaylistAt stamping rule. The decision is logged
  in TODO.md "Behavior Decisions" with the rationale that BUG-6's fix keeps
  the data accurate for a future missing-from-remote feature.
- BUG-6 (low, FIXED 2026-07-19): `lastSeenInPlaylistAt` was stamped only
  when the item upsert reported didChange, so for unchanged items it stayed
  at first-insert time forever, poisoning any future missing-from-remote
  logic. Now stamped via PlaylistSyncService.shouldRefreshLastSeen: on any
  change, on first sighting, and for unchanged items whenever the stamp is
  older than 24h — deliberately NOT unconditionally, because a fresh date
  every 30-minute cycle would dirty every item record and churn CloudKit;
  day resolution is enough for any pruning decision. Tests added in
  PlaylistSyncReconciliationTests.
- PERF-6 (low-medium, FIXED 2026-07-19): reconcile did 2 extra indexed
  fetches PER TRACK purely to feed a .debug log line even when debug
  logging was off (~1000 wasted main-actor fetches per 500-track cycle).
  The pre-upsert lookups and logFoundRemoteTrack are now gated on
  `OSLog.isEnabled(type: .debug)` — zero cost unless someone is actually
  watching the debug stream.
- NOTE: `ModelContext.ephemeral` (PlaylistSyncService.swift:505-513) uses
  `try!` — acceptable (static in-memory schema), but a failed container
  init would crash instead of surfacing an error.

### Chunks 8+9 — Repositories, Views, ViewModels

Repositories: clean throughout (indexed single-row fetches with fetchLimit 1
and includePendingChanges; explicit saves on every mutation path — which is
what makes the CarPlay secondary context safe).

- PERF-7 (medium-high, FIXED 2026-07-19): HistoryView held an unbounded
  `@Query` over ALL HistoryEvent rows and re-derived presentation models
  from the full array on every body pass. Now: events load through
  EventRepository.recentEvents — predicate-filtered in the store (predicates
  mirror HistoryEventFilter.includes, verified by a parity test), sorted
  newest-first, fetchLimit'd to a 100-row page with a "Show More" row
  (limit+1 fetch detects more). The recovery summary reads only reconciled
  playthroughs via its own predicate fetch. Reloads are keyed on
  filter/limit/metadata-version instead of the full result set. Tests:
  EventRepositoryTests.
- BUG-7 (medium, release-hardening, FIXED 2026-07-19): no retention policy
  for HistoryEvent — unbounded growth in the store AND CloudKit. Now:
  HistoryRetentionService.compact runs at startup (AppStartupViewModel
  authorized-services sequence): skipIgnored noise expires after 30 days,
  everything else after 365, capped at 500 deletions per run so backlogs
  drain across launches without stalling startup. Tests:
  HistoryRetentionServiceTests.
- PERF-8 (low-medium): PlaylistManagementView computes `detailPresentation`
  (full row-model build for all items) at the top of every body evaluation
  (:34, :176-190), and `selectedPlaybackOrderState` (:164-170) runs
  PlaybackOrderCoordinator.reconciledState, which can WRITE to UserDefaults
  — a side effect inside body. Body re-runs on every observed
  playbackController change (metadata version bumps per transition), not
  per-second, so it's tolerable; memoizing on (items, scope, version) would
  remove the churn and the body-time write.
- NOTE (good): ArtworkView decodes thumbnails off-main via ImageIO with an
  actor LRU (300 images) and defers loads while scrolling
  (loadsArtworkImmediately: !isScrolling). Progress bar isolation keeps
  per-second re-render small. DashboardView/SelectionView/HistoryView all
  use the repository-backed @State pattern now.

### Chunk 12 — Offline / delivery-failure resilience (field report follow-up)

Field report: twice, while driving through low-connectivity areas, playback
stopped dead and the Apple Music app itself had failed. Traced how Overplay
reacts when the player cannot deliver the next track. Short answer: it
doesn't — there is no failure handling for streaming delivery at all. Grep
confirms zero handling of `MusicPlayer.PlaybackStatus.interrupted` (the SDK
defines it), no reachability monitoring (no NWPathMonitor), no retry, and no
auto-resume anywhere in the playback layer.

The four failure paths:

A. Mid-track stall (currentEntry stays set, status .paused/.interrupted or
   .playing with frozen position): `PlaybackQueueEndPolicy.queueDidEnd`
   requires hasCurrentEntry == false, so it never fires. The 1 Hz refresh
   keeps recording a frozen elapsed time. No stall detection, no
   statusMessage, no retry. Playback is silently dead.

B. Player abandons the queue (currentEntry → nil, status .stopped/.paused):
   queueDidEnd fires, but `shouldRestartAfterQueueEnd` deliberately demands
   the outgoing session was observed within 3s of track end (the
   anti-surprise-restart guard, PlaybackQueueEndPolicy.swift:25-28). A
   network failure mid-track fails that test, so the only reaction is a
   diagnostic log (`logQueueEndWithoutRestartIfNeeded`,
   PlaybackController.swift:1711). The UI keeps displaying the stale track
   via the activeQueueCurrentEntry identity fallback (:1624-1632), paused
   forever. If the status is .interrupted with a nil entry, queueDidEnd is
   false and not even the log fires. This matches the reported symptom
   exactly.

C. User presses Next while delivery is failing (app, CarPlay, or Lock
   Screen — all reach PlaybackController.next): `skipToNextEntry()` throws →
   the catch calls `handleQueueEnded` (:585-592), which DESTRUCTIVELY
   reshuffles the stored playback order (persisted immediately,
   flushImmediately: true, via PlaybackQueueOrchestrator
   .reshuffledQueueEntries → PlaybackOrderCoordinator.reshuffle), replaces
   the live player queue and activeQueueEntries (:1954-1958), and only THEN
   discovers `play()` also throws. Net effect of a failed skip while
   offline: the user's shuffle order is discarded and the queue is
   repositioned to a random first track at 0:00 before playback ability was
   ever confirmed. When connectivity returns, pressing play resumes
   somewhere unexpected. The error lands in statusMessage, which renders
   ONLY in the iPhone/iPad Now Playing views — from CarPlay or the Lock
   Screen (where both field incidents occurred) there is zero feedback.

D. Music app process dies: ApplicationMusicPlayer reports an empty/stopped
   state → same dead end as B. Only an explicit user play() would relaunch
   Music; Overplay never attempts recovery on its own.

Interaction with SURF-1/SURF-2: while driving, Overplay is typically
suspended, so the stall isn't even witnessed live; on next unlock the app
sees a stale stopped player and — per the staleness rules — correctly counts
nothing, but also does nothing to recover.

Findings:
- BUG-8 (medium-high, field-confirmed, FIXED 2026-07-19): no
  delivery-failure handling. Mid-track network failure ended in silent
  permanent stop (paths A/B/D); `.interrupted` was unhandled; no stall
  detection, retry, reachability awareness, or auto-resume; no user-visible
  error on CarPlay/Lock Screen. Implemented: (1) new pure
  PlaybackDeliveryStallPolicy — 3 consecutive `.interrupted` ticks or 5
  frozen-position `.playing` ticks (paths A + the .interrupted variant of
  B) mark delivery stalled; fed from the 1 Hz refresh. (2) Observable
  `PlaybackController.isDeliveryStalled` + statusMessage; CarPlayCoordinator
  observes it and presents one CPAlertTemplate per stall episode. Path B
  proper (queue abandoned, restart declined) also surfaces a "playback
  stopped" message + the CarPlay alert when Overplay itself had started
  playback, but never auto-resumes there (indistinguishable from an
  external stop). (3) Bounded auto-recovery: prepareToPlay()+play(), max 2
  attempts per episode, gated on NWPathMonitor reachability
  (NetworkReachabilityMonitor) AND a new `playbackIntended` flag (set only
  by user play commands, cleared by pause) so it can never auto-play after
  an intended stop; only runs for detector-confirmed stalls. Cleared by
  witnessed playback progress or a successful user play. Tests:
  PlaybackDeliveryStallPolicyTests.
- BUG-9 (medium, FIXED 2026-07-19): the failed-skip path was destructive
  before it was confirmed. handleQueueEnded persisted a reshuffled order
  and replaced the live queue BEFORE play() succeeded; a thrown play() left
  order + queue position lost. Now: PlaybackQueueOrchestrator
  .previewedReshuffledQueue computes the order WITHOUT saving; the active
  queue is adopted and the order persisted (persistReshuffledOrder) only
  after play() returns; on a thrown play() the player queue is rebuilt from
  the untouched stored order positioned at the track the user was on, the
  delivery failure is surfaced (drives the CarPlay alert — path C feedback
  gap closed), and a later manual play resumes there. Tests:
  PlaybackQueueOrchestratorTests (preview never persists; persist saves
  under the scoped playlist ID). Tightened further: a thrown
  skipToNextEntry mid-queue with a live entry can only be a delivery
  failure, so next() no longer attempts the queue-end reshuffle-restart at
  all in that case (PlaybackQueueEndPolicy.skipFailureIndicatesQueueEnd) —
  the restart path is reserved for the final entry, an abandoned entry, or
  an unknown queue position, where queue end cannot be ruled out.
- NOTE (minor, acceptable): next() counts the outgoing skip before the
  transition is attempted, so a failed skip still records the skip. The
  user did intend to skip, and the alternative (counting after) would lose
  witnessed state — leave as is.

## SYNTHESIS — ranked findings

Overall: the codebase is in good shape. Layering is disciplined (pure policy
enums, repositories, one shared controller), every cross-surface action
routes through PlaybackController, every mutation saves explicitly, and the
witnessed-listening capture rules are correctly implemented and
double-count-proof. No high-severity correctness bug was found. Ranked:

1. BUG-8 + BUG-9 — FIXED 2026-07-19 (stall detection + CarPlay alert +
   gated bounded auto-retry; failed restarts no longer persist the
   reshuffled order or lose queue position). Was: no delivery-failure
   handling (silent permanent stop on mid-track network failure;
   .interrupted unhandled; no feedback on CarPlay/Lock Screen) and the
   failed-skip path destructively reshuffled order + repositioned the queue
   before play() was confirmed. FIELD-CONFIRMED twice while driving through
   low-connectivity areas. See Chunk 12. Field re-verification on device
   (drive through a dead zone) still worthwhile.
2. PERF-7 + BUG-7 — FIXED 2026-07-19 (paged, predicate-filtered history
   loading via EventRepository.recentEvents + Show More; startup retention
   pass — skipIgnored 30d, all events 365d, 500/run cap). Was: HistoryView
   unbounded @Query over ALL events + no retention policy for HistoryEvent
   (grows forever, syncs to CloudKit).
3. PERF-1 — FIXED 2026-07-19 (monitor self-suspends after 5 idle minutes
   and resumes on any play path; settings + known-music-ID caches remove
   the per-tick fetches). Was: 1 Hz monitor never stopped once started and
   did 3-4 SwiftData fetches per tick even while paused for hours.
4. SURF-1/SURF-2 — playback while Overplay is suspended is uncounted by
   design (no phantom skips — correct; but playthroughs completed while
   suspended are lost, and Lock Screen presses while suspended bypass
   counting). RESOLVED (2026-07-19, IMPLEMENTED): background-wake
   reconciliation that recovers suspended playthroughs while preserving the
   unwitnessed-skips-never-count guarantee. Implementation:
   PlaybackReconciliationPolicy + PlaybackWaypointStore (pure policy +
   UserDefaults waypoint with counted-track ledger),
   PlaybackReconciliationService (counts via EvictionEngine.countPlaythrough
   with new source/message params, logs HistoryEventSource.reconciled,
   lastPlayedAt + live-session dedupe guards),
   PlaybackBackgroundRefreshService (BGTaskScheduler registration + aimed
   re-arm), OverplayApp scenePhase hooks (background = exact baseline
   waypoint + arm wake; active = reconcile before staleness discard),
   Info.plist fetch background mode + BGTaskSchedulerPermittedIdentifiers,
   PlaybackController.capturePlaybackObservation/
   markActiveSessionPlaythroughCounted. Tests:
   PlaybackReconciliationPolicyTests (point/continuity proofs, tolerance,
   dedupe, wake aiming). REMAINING DEVICE VERIFICATION: whether
   ApplicationMusicPlayer state is readable during a BGAppRefresh wake
   (diagnostics logged per wake); actual grant cadence. Design rationale
   kept below for the record.
   - Proof rules (either counts a playthrough; anything ambiguous counts
     nothing): POINT-PROOF — any snapshot showing the current track at
     position >= playthroughThresholdPercentage (90) counts it outright,
     consistent with the existing position-based rule (BUG-2: seeks
     already count); immune to earlier pauses/stalls. CONTINUITY-PROOF —
     between two waypoints, if elapsed wall time matches the sum of
     traversed track durations (queue order from PlaybackOrderStore,
     durations from TrackRecord.durationSeconds; tolerance ~3s per
     boundary + 5s base), every completed track in the span counts; any
     mismatch (pause, skip, stall, unknown duration) means nothing in that
     span is counted. Skips: never reconstructed.
   - Wake scheduling: BGTaskScheduler allows ONE pending BGAppRefresh
     request per identifier and grant delay is one-sided (late only), so
     each wake aims earliestBeginDate at the 90% CROSSING OF THE CURRENT
     TRACK: now + (0.9*dur - pos), or if already past it,
     now + (dur - pos) + 0.9*durNext; +5s margin, clamped >= 60s. A grant
     landing inside the [90%, end] window point-proves; a late grant lands
     early in the next track, pinning the boundary tightly for continuity.
     A 50% "skip-neutral" wake is deliberately omitted — suspended skips
     are never counted, so it yields no retainable data and would displace
     the higher-value 90% request.
   - Wake cycle (BG grant, foregrounding, or scenePhase->background
     flush): snapshot player state -> point-proof current track ->
     continuity-reconcile the span since the last waypoint -> persist new
     waypoint -> re-arm at the next 90% crossing.
   - Components: pure PlaybackReconciliationPolicy (+tests),
     PlaybackWaypointStore (UserDefaults, LocalPlaybackStateStore pattern),
     PlaybackReconciliationService counting via the existing
     EvictionEngine.countPlaythrough(item:...) (already takes an explicit
     item) and logging history with a new HistoryEventSource.reconciled;
     BGTaskScheduler registration in OverplayApp + Info.plist additions
     (UIBackgroundModes fetch, BGTaskSchedulerPermittedIdentifiers);
     scenePhase handler force-flushing LocalPlaybackStateStore on
     background (exact baseline instead of the 15s pacing). Double-count
     guard: reconciliation marks the live activeSession hasEvaluated when
     it point-proves the current track; the relaunch restore path already
     builds sessions with hasEvaluated: true.
   - Open risks: whether ApplicationMusicPlayer state is readable from a
     BGAppRefresh wake (device-verify with diagnostics; fallback
     MPMusicPlayerController.systemMusicPlayer, worst case
     foreground-only reconciliation — still a win given the exact
     background-flush baseline); BG grant cadence will be sparser than one
     per track (degrades to longer continuity spans, never wrong counts);
     requires the user's Background App Refresh setting (the foreground
     path works regardless). The CarPlay-scene device check (TODO.md)
     should run first — while Overplay's CarPlay template is on the car
     display the process is foreground there and counting already works,
     which may cover the driving case outright.
5. DOC-2 + BUG-6 — FIXED 2026-07-19 (spec component summary now matches the
   leave-in-place removals behavior, decision logged in TODO.md;
   lastSeenInPlaylistAt refreshes on change/first sighting/daily for
   unchanged items — not every cycle, to avoid CloudKit write churn).
6. PERF-4 — FIXED 2026-07-19 (misses negative-cached per musicItemID,
   invalidated on metadata changes, sync reconciles, and reset). Was:
   worst-case per-tick full TrackRecord table scan when an unresolvable
   track is playing.
7. PERF-6 — FIXED 2026-07-19 (debug-only lookups gated on
   OSLog.isEnabled(.debug)). Was: sync reconcile burned 2 fetches/track
   feeding disabled debug logs (~1000 wasted main-actor fetches per
   500-track sync).
8. PERF-5 — CarPlay observes elapsedSeconds it never uses → per-second
   settings+signature fetches while connected.
9. BUG-4 — RemoteCommandService keeps the orphaned CarPlay ModelContext
   after disconnect (works, but re-point on disconnect).
10. BUG-2/BUG-3 — playthrough counts on seek past threshold (position-based,
    product decision); UI skip-hint uses position while engine uses witnessed
    listening (can disagree after seeks).
11. CLEANUP-1 — evictedDuringEvaluation is dead since auto-eviction removal;
    remove the flag + branches; reorder removeEvictedItemFromPlaylist ID
    resolution to item-first when touching it.
12. PERF-2/PERF-8/PERF-3 — per-transition full-playlist snapshot rebuild;
    PlaylistManagementView body-time presentation build + UserDefaults write
    side effect; rare full-playlist fallback in resolvePlaylistItem.

README: updated this review (config paths; removals claim now matches
implementation). Remaining README claims verified against code: One True
Playlist/triage model ✓, witnessed-listening skip rule ✓, retirement flow
incl. remote-removal policy ✓, shared-controller surface parity ✓
(structurally; device checklist still open), local-only playback state ✓,
project-shape list ✓.

Validation answers for this review's two explicit questions:
- Same behavior across app/CarPlay/Lock Screen/Control Center: YES
  structurally — all transports converge on PlaybackController.next/
  previous/togglePlayPause/pause; CarPlay custom actions call the same
  controller methods as in-app buttons; shuffle converges on
  reshuffleCurrentPlaylist via RemoteCommandService from both surfaces.
  Runtime confirmation on hardware remains on the TODO.md checklist.
- Skips/playthroughs captured regardless of surface/backgrounding: captured
  identically for any surface WHILE THE PROCESS RUNS (all paths evaluate the
  outgoing session before transitioning). While suspended: nothing is
  counted (deliberate no-phantom-skips tradeoff); transitions that happened
  out-of-process are recognized as unwitnessable on resume and logged as
  skipIgnored. Playthroughs that complete >5s after the last witnessed poll
  are lost unless the last observation was within 3s of track end.
