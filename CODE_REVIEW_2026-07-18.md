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

- PERF-1 (medium): the 1 Hz monitor (`startMonitoring`,
  PlaybackController.swift:180) runs for the rest of the app's life once
  playback has started — it is never cancelled, even when playback has been
  paused/stopped for hours. Every tick executes several SwiftData fetches on
  the main context: `SettingsRepository.settings` (refresh →
  evaluatePlaythroughIfNeeded:1273), `currentTrackKnownMusicItemIDs` fetches
  the current TrackRecord (:1251-1261), and `recordTrustedRuntimeAlias`
  fetches the TrackRecord again on the realized-entry hot path (:1495-1505).
  ~3-4 fetch-descriptor executions per second on the MainActor while idle.
  Fix direction: cancel/suspend the monitor after N minutes paused (resume on
  play), and cache settings + current track's musicItemIDs keyed by identity,
  invalidating on change.
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

- PERF-4 (medium): `PlaybackQueueCoordinator.localTrackID(matching:)`
  (:100-110) falls back to fetching ALL TrackRecords and scanning when the
  indexed catalog/library lookup misses. PlaybackController.localTrackID
  (:1448-1478) reaches it (a) whenever the scoped playlist lookup throws and
  (b) unconditionally when no playlist is set. If an unresolvable track is
  playing (e.g. queue-reported ID that matches no record), the 1 Hz refresh
  re-runs this full-table scan EVERY second (resolvedCurrentPlaybackIdentity
  :1583 → localTrackID(matching:)). Fix: negative-cache the miss per
  musicItemID until identity changes.
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

- DOC-2 (medium, README FIXED / spec still inconsistent): remote REMOVALS
  are not reconciled — PlaylistSyncService.reconcile only upserts; nothing
  ever prunes or marks items missing from the remote playlist, and
  `lastSeenInPlaylistAt` is written but never read. README claimed
  "additions, removals, and reordering reconciled" — corrected to describe
  actual leave-in-place behavior. The DESIGN SPEC contradicts itself:
  "Removals from Apple Music" (line ~230) says leave items in place
  (matches code), but the PlaylistSyncService component summary (line ~779)
  says "Reconcile additions and removals. Mark external removals as manual
  retirement/removal events" (not implemented). Spec needs one answer;
  TODO.md "Behavior Decisions" is the right place to log it.
- BUG-6 (low): `lastSeenInPlaylistAt` is stamped only when the item upsert
  reports didChange (PlaylistSyncService.swift:265-267), so for unchanged
  items it stays at first-insert time forever. Spec says every sync sighting
  should set it. Harmless today (nothing reads it), but it poisons any
  future missing-from-remote logic. Stamp it unconditionally.
- PERF-6 (low-medium): reconcile does 2 extra indexed fetches PER TRACK
  purely to feed a .debug log line (existingTrack/existingItem,
  PlaylistSyncService.swift:236-247), even when debug logging is off, and
  the upserts immediately re-resolve the same records. On a 500-track
  playlist that's ~1000 wasted main-actor fetches per sync cycle. Gate on
  Logger.isEnabled(.debug) or reuse the upsert results for logging.
- NOTE: `ModelContext.ephemeral` (PlaylistSyncService.swift:505-513) uses
  `try!` — acceptable (static in-memory schema), but a failed container
  init would crash instead of surfacing an error.

### Chunks 8+9 — Repositories, Views, ViewModels

Repositories: clean throughout (indexed single-row fetches with fetchLimit 1
and includePendingChanges; explicit saves on every mutation path — which is
what makes the CarPlay secondary context safe).

- PERF-7 (medium-high): HistoryView holds `@Query(sort: .createdAt,
  .reverse)` over ALL HistoryEvent rows (HistoryView.swift:8) with no
  fetchLimit or pagination, and `rows` re-derives presentation models from
  the full array on every body pass (:63-69). Every playback transition
  writes at least one event (skipCounted/skipIgnored/playthrough all log),
  so this grows without bound; after months the History screen loads
  thousands of models and re-diffs them on every save that occurs while
  visible. Fix: fetchLimit + load-more, and filter via the Query predicate
  instead of in-memory.
- BUG-7 (medium, release-hardening): no retention policy for HistoryEvent
  anywhere — unbounded growth in the store AND in CloudKit (records sync).
  skipIgnored "noise" events (every pause/short-listen transition) make up
  much of it. Add retention/compaction before beta; TODO.md release section
  should mention it.
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
2. PERF-7 + BUG-7 — HistoryView unbounded @Query over ALL events + no
   retention policy for HistoryEvent (grows forever, syncs to CloudKit).
   Biggest real-world perf risk as usage accumulates.
3. PERF-1 — 1 Hz monitor never stops once started and does 3-4 SwiftData
   fetches per tick even while paused for hours (settings, track record ×2).
4. SURF-1/SURF-2 — playback while Overplay is suspended is uncounted by
   design (no phantom skips — correct; but playthroughs completed while
   suspended are lost, and Lock Screen presses while suspended bypass
   counting). Document as product behavior; device checklist confirms.
5. DOC-2 + BUG-6 — remote removals are NOT reconciled (README fixed; spec
   self-contradicts at ~line 230 vs ~line 779); lastSeenInPlaylistAt goes
   stale for unchanged items and would poison future pruning.
6. PERF-4 — worst-case per-tick full TrackRecord table scan when an
   unresolvable track is playing (needs a negative cache).
7. PERF-6 — sync reconcile burns 2 fetches/track feeding disabled debug logs
   (~1000 wasted main-actor fetches per 500-track sync).
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
