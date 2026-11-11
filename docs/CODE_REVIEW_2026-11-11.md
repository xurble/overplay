# Overplay Code Review — 2026-11-11

A review of the whole codebase at commit `2e2bcb7` (main). It covers the app
(`Overplay/`, about 41,000 lines of Swift), the tests (`OverplayTests/`,
`OverplayUITests/`), the Xcode project and configuration, and the docs.

## How to read this

**Method.** The code was read in six slices: playback engine, sync and library
services, persistence and artwork, CarPlay/Siri/app shell, SwiftUI views, and
tests plus build configuration. Nothing was built, run or profiled. Every
finding comes from reading the code and its callers.

**Confidence.** Each finding carries one of three levels:

- **Confirmed**: the code path was traced end to end.
- **Likely**: the code path is traced, but the trigger depends on behaviour
  that was not observed (Apple Music responses, OS behaviour, signing).
- **Speculative**: the hazard is real in the code, but no current path is
  proven to reach it.

A ✔ after the confidence means the cited code was read a second time while
this report was assembled and the stated facts hold. It does not mean the
failure was reproduced.

**Severity.** High means a crash, lost data or a wrong change to the Apple
Music library that is plausible in normal use. Medium means a user-visible
fault that needs a particular situation, or a cost that grows with library
size. Low is everything else worth fixing.

**Performance findings are unmeasured.** They describe work the code does, not
time it was seen to take. Profile before spending effort on any of them.

**Out of scope.** Items the spec already lists under Known Defects and
Verification Gaps were left out. Missing data migrations were not counted, per
the pre-release data policy.

Finding IDs (`CR-1`, `DI-2` and so on) exist only so this document can be
referred to; they are not spec requirement IDs.

## Summary

The code is in good shape for its size. There are no `as!`, no `print`, no
`TODO` markers, one `fatalError`, one `@unchecked Sendable`, and Swift 6 mode
is on for every target. The pagers that feed destructive sync steps fail
closed. The tests are numerous (1,079) and assert on behaviour rather than on
canned values. Most of what follows is about edges, scale and release
readiness rather than broken fundamentals.

The items most worth acting on first:

| ID | What | Severity |
|---|---|---|
| CR-1 | Save to Photos on the Mac has no usage description and probably terminates the app | High (Mac) |
| DI-1 | A removal queued behind a promotion can delete the just-promoted song from Apple Music | High |
| REL-1 | The activity-log screens testers are told to use are compiled out of Release | High |
| PB-1 | A hung player call inside the observation path stops observation until relaunch or foreground | Medium |
| PB-2 | A second tap during a start plays the still-loading queue | Medium |
| PB-3 | A start that never played clears the failure that was showing | Medium |
| PB-4 | Network-return recovery stops working after one hung attempt | Medium |
| PA-1 | The dashboard Play button decides resume versus start in the view and skips the shuffle rule | Medium |
| PA-2 | CarPlay Promote, Retire and Restore failures are silent in the car | Medium |
| CO-1 | The save-notification filter compares typealias names, so it never matches the real entities | Medium |
| DI-3 | One song missing from the web library fails that playlist's sync on every cycle | Medium |
| API-1 | Promoting a song that has only a library ID always fails | Medium |
| CR-2 | Unguarded KVC on AppKit windows can raise an uncatchable exception on the Mac | Medium |
| TST-1 | `CarPlayCoordinator` (1,433 lines) has no tests, so adapter routing is unprotected | High (coverage) |

## TestFlight feedback against these findings

Build 1 (version 2026) has no crash reports as of 6 November. One tester
(iPhone, iOS 27.2, US locale) sent three screenshot reports and one comment
without a screenshot. None of the causes below is proven: the tester's
activity log would settle each, and it cannot be shared from a Release build
(REL-1).

### TF-1. Every Inbox source fails to sync (4 and 6 November)
- Seen: Inbox Sources lists BARS, Breaking R&B, Country Risers, Indie
  Electronic and more, each "0 tracks · The operation couldn't be completed.
  (MusicKit.MusicDataRequest.Error error 1.)". After a reinstall with one
  source (New Music Daily) the result is the same, with the toast "Apple Music
  couldn't find that."
- What the code says: that toast is the text for an HTTP 404
  (`Overplay/Presentation/UserFacingError.swift:56`). The song resolver
  handles a 404 from the web library
  (`MusicLibrarySongResolver.swift:163-165`). The identity step that follows
  does not: `MusicIdentityResolver.liveFetch` (`:252-262`) lets a 404 from
  `/v1/me/library/songs?ids=…&include=catalog` or the catalog songs request
  propagate, and one failed batch fails the whole playlist. This is DI-3, here
  hitting every song rather than one.
- Not known: which request returned 404, and why it does for this account and
  not the developer's. Candidates are the web library not returning songs the
  device's library query does, and a storefront or account-state difference.
- Also a presentation fault: the row shows the raw `localizedDescription`
  rather than the friendly message the toast uses.

### TF-2. "Couldn't add … This track does not have an Apple Music identifier Overplay can add" (4 November, "quite a bit")
- Seen: playing She Sells Sanctuary from the playlist "'80s Alternativ…",
  using the add-to-One-True-Playlist button.
- What the code says: that message is `PlaylistMutationError.musicItemMissing`,
  thrown at `PlaybackController.swift:1910`. `confirmedIdentity(forSongID:)`
  asks the catalog, then the web library. When only the web library knows the
  ID it returns a library-only identity, and adding to the One True Playlist
  then requires a catalog ID and refuses. So a song reached through a library
  playlist, whose ID is a library ID, cannot be added to the One True
  Playlist. Adding it to the Inbox does not hit that guard.
- This is the same gap as API-1 from the other direction. The fix is the
  same: when only a library ID exists, add the library song
  (`MusicLibraryRequest<Song>`), or take the catalog ID from the library
  resource's catalog relationship.
- Confidence: likely. The path is traced; that this song's ID was a library
  ID is inferred from the message.

### TF-3. Phone runs hot
No evidence beyond the comment. The review's candidates, in the order worth
profiling:
- A failing source sync repeats its work every cycle. With every source
  failing (TF-1), each 30-minute cycle re-runs one MusicKit request per song
  per playlist (PF-12) and never records a successful fetch to skip on.
- The player re-evaluates its whole pane every second with four SwiftData
  fetches, eight with the full player open (PF-4).
- Device motion at 30 Hz drives a redraw of a blurred image larger than the
  screen, and the progress bar rebuilds its glass capsule 30 times a second
  (PF-11). Neither stops when the app is backgrounded.
- Two of the three reports came from sessions 2 and 13 hours old, so the app
  stays alive for long stretches.

An Instruments Time Profiler or Energy Log run on a device, with the full
player open and a failing source linked, would show which of these matters.

## 1. Crash risks

### CR-1. Save to Photos on Mac Catalyst has no usage description
- Severity: high on Mac. Confidence: likely ✔ (configuration confirmed; the
  crash was not run).
- Location: `Config/Info-MacCatalyst.plist` (key absent), `Config/Info.plist:31`
  (present), `Overplay/Services/CollagePhotoSaver.swift:22`,
  `Overplay/Views/Components/PlaylistCollageView.swift:26,31,79-91`.
- What: `NSPhotoLibraryAddUsageDescription` is in the iOS plist only. The
  Catalyst entitlements grant Photos access, and the "Save to Photos" context
  menu item and accessibility action are not hidden on the Mac. Commit
  `0042cde` added the key to one plist and noted "not tried on Mac".
- Trigger: on the Mac, choose Save to Photos on a collage.
  `PHPhotoLibrary.requestAuthorization(for: .addOnly)` without a usage string
  normally terminates the process. It is also an App Review rejection.
- Fix: copy the key into `Info-MacCatalyst.plist`, or hide the action on
  Catalyst. A small test that diffs the two plists against an allow-list would
  stop them drifting again (`Shared.xcconfig` says to keep them identical).

### CR-2. `MacAppKitWindow.nsWindow(for:)` uses unguarded KVC
- Severity: medium. Confidence: likely ✔.
- Location: `Overplay/Views/SettingsWindowView.swift:168-171` (also `:175`, `:183`).
- What: the lookup calls `value(forKey: "uiWindows")` on every object in
  `NSApplication.windows`. An object without that key raises
  `NSUnknownKeyException`, which Swift cannot catch. The selectors used
  elsewhere in the file are checked with `responds(to:)`; this key is not. The
  comment "if AppKit changes, each call does nothing" does not hold for this
  line.
- Trigger: `NSApp.windows` on Catalyst can hold windows that are not UIKit
  hosts (tooltip panels, popovers, menus, share pickers). If one is ahead of
  the Settings window when Settings opens or resizes, the app crashes. These
  are also private AppKit keys, which is a review risk for a Mac release.
- Fix: guard each element with `responds(to: NSSelectorFromString("uiWindows"))`
  before the KVC call.

### CR-3. A model container failure is a `fatalError` with no recovery
- Severity: medium. Confidence: confirmed.
- Location: `Overplay/OverplayApp.swift:47-56`; throwing sources in
  `Overplay/Persistence/AppPersistence.swift:99-149`.
- What: any failure to open the store (a schema SwiftData cannot migrate, an
  unreadable file, a missing CloudKit container identifier) crashes at launch.
  That applies equally to CarPlay scene connects, Siri intents and background
  wakes. The pre-release "schema reset" policy has no code path here, so the
  only recovery is deleting the app.
- Fix: catch the error, leave the store file alone and show a blocking error
  screen. This belongs with `docs/TODO.md` item 1.4.

### CR-4. `CarPlayListRenderer.update` traps on a repeated row ID
- Severity: low. Confidence: speculative ✔ (the trap is certain given a
  duplicate; no current data path is proven to produce one).
- Location: `Overplay/CarPlaySupport/CarPlayListRenderer.swift:187`.
- What: `oldRows` is built with `Dictionary(uniqueKeysWithValues:)`. Two lines
  later `styles` uses `uniquingKeysWith`, so tolerance was the intent. Song
  lists are de-duplicated upstream, but Library category rows come from paged
  web requests with no de-duplication by ID.
- Trigger: a library change between pages returns one album twice. The first
  render is fine; the next refresh of that list crashes Overplay in the car.
- Fix: use `Dictionary(_:uniquingKeysWith:)` on that line and add a
  duplicate-ID case to `CarPlayListRendererTests`.

### CR-5. CarPlay row closures capture `PlaylistRecord` models
- Severity: low. Confidence: speculative.
- Location: `Overplay/CarPlaySupport/CarPlayCoordinator.swift:848-853`, `1377-1389`.
- What: the Shuffle and track-row closures hold the model object. When the
  visible playlist can no longer be fetched, `refreshLibraryLists` returns
  early and the old closures stay live.
- Trigger: the record is deleted while its list is on screen (Nuke Database
  on the phone during a CarPlay session). A tap passes an invalidated model to
  `playPlaylist`.
- Fix: capture `playlist.id` and refetch in the handler, as `playRecent`
  already does.

### CR-6. `extractPalette` keeps an array pointer past the call it was valid for
- Severity: low. Confidence: confirmed ✔ for the code, speculative for any
  consequence.
- Location: `Overplay/Presentation/AlbumArtworkTheme.swift:1060-1073`.
- What: `CGContext(data: &pixels, …)` uses an implicit inout-to-pointer
  conversion, valid only for that initialiser call. The context keeps the
  pointer and `draw` writes through it afterwards. It works because the array
  storage happens to be stable, but it is undefined behaviour.
- Fix: pass `data: nil` and read `context.data`, or do the create, draw and
  read inside `pixels.withUnsafeMutableBytes`.

### CR-7. `removeTriageSources(at:)` indexes a filtered array while mutating it
- Severity: low. Confidence: speculative.
- Location: `Overplay/Views/TriageSourcesView.swift:192-196`.
- What: safe for the single offset a swipe delivers today. A multi-row delete
  would address the wrong playlist or go out of range.
- Fix: collect the targets before the loop.

### Sweep results
Across `Overplay/`: `try!` ×4 (one in a preview, three constant regex
literals), `as!` ×0, `fatalError` ×1 (CR-3), `precondition` ×1 (unreachable
while `PlaylistSource` has one case), `.first!`/`.last!` ×0, `URL(string:)!`
×1 (a constant). `Dictionary(uniqueKeysWithValues:)` appears in
`MusicIdentityResolver` on IDs already passed through a `Set`, and at CR-4.

## 2. Data integrity and sync

### DI-1. A removal queued behind an in-flight promotion can delete the promoted song
- Severity: high. Confidence: likely ✔ (the ordering is confirmed in code; the
  outcome needs iCloud to list the new song by the time the removal runs).
- Location: `Overplay/Services/OneTruePlaylistRemoteMembership.swift:69-78`,
  `Overplay/Services/PlaylistMutationService.swift:88-95`.
- What: a promotion first marks the Inbox row with the One True Playlist's
  suppression and saves, then awaits the remote add. `removeSongsHeldOutside`
  collects "every row outside the playlist carrying that suppression" before
  it takes the remote-mutation gate, and never re-reads it once it holds the
  gate. A removal that starts during a promotion therefore captures the song
  being promoted.
- Trigger: promote song X (the network add takes a few seconds), then retire
  song Y, or let a periodic sync call `retryRemoteRemovals`. The removal
  queues with X in its set. The promotion finishes. The removal then rewrites
  the playlist without X. Overplay shows X in the One True Playlist; Apple
  Music no longer has it; nothing re-adds it.
  `DuplicateTrackService.prepareOTPMembership` (244-263) uses the same
  suppress-then-add pattern.
- Fix: build the set inside the `perform` closure, after the gate is held, or
  re-filter it there against live rows. Add an interleaving test to
  `OneTruePlaylistRemoteMembershipTests`.

### DI-2. Sync releases suppression on absence from the device's copy, not iCloud's
- Severity: medium. Confidence: likely.
- Location: `Overplay/Services/PlaylistSyncService.swift:625-634`.
- What: after a complete read of the One True Playlist, rows whose track is
  not in the snapshot lose their suppression, and a retired 0/0 row is
  deleted. The snapshot is this device's library copy, which the spec itself
  says can lag iCloud. `removeSongsHeldOutside` checks the web library for
  exactly that reason; this block draws the same conclusion from weaker
  evidence and runs first.
- Trigger: X is promoted on the phone; the Mac's copy does not list it yet;
  the user retires X on the Mac. The next sync there does not see X and
  releases the suppression. A 0/0 row is deleted and X later re-imports as
  active (retirement undone). A row with plays stays retired but X is never
  removed from Apple Music.
- Note: `GlobalTrackOwnershipTests.swift:169` asserts "proven absence releases
  suppression", so the behaviour is intended. The gap is what counts as proof.
- Fix: for a managed One True Playlist, let `removeSongsHeldOutside` be the
  only releaser.

### DI-3. One library song the web library does not return fails the whole playlist sync
- Severity: medium. Confidence: likely ✔.
- Location: `Overplay/Services/MusicIdentityResolver.swift:109-112`, `:280`;
  called from `Overplay/Services/AppleMusicPlaylistSourceSync.swift:113,152`.
- What: `PLAYLIST-010` skips songs nothing can identify. But a song the native
  library lookup does resolve must then come back from
  `/v1/me/library/songs?ids=…`. If any requested ID is missing, `decode` and
  `enrich` throw `incompleteResponse`, and the whole fetch fails.
- Trigger: a playlist holds one song that is in the device library but not the
  account's web library (a local-only file, or a lagging device). That
  playlist records an error every cycle until the song is removed. A comment
  at `DuplicateTrackService.swift:198-200` acknowledges the behaviour.
- Fix: treat a missing library resource as unresolved under `PLAYLIST-010`,
  reusing the bisecting approach in `enrichSkippingUnanswered`.
- Open question: whether native library IDs on a Mac are returned by the web
  library at all. If not, this affects every Mac sync. It needs a live check.

### DI-4. `SettingsRepository.settings(in:)` creates a settings row on a miss
- Severity: medium. Confidence: confirmed ✔ for the lock-out once two rows
  exist; speculative for the trigger.
- Location: `Overplay/Persistence/SettingsRepository.swift:6-20`; gate at
  `Overplay/Persistence/LibraryRestorationService.swift:53-55,123`.
- What: the accessor inserts and saves a new row whenever the fetch is empty.
  Restoration requires exactly one settings row and nothing converges
  duplicates.
- Trigger: device A runs Nuke Database (delete all, then insert). Device B
  imports the deletion before the new row, and its next `settings(in:)` call
  creates a second row, which syncs. From the next launch every device fails
  restoration with "Your library is still arriving from iCloud".
- Fix: make the accessor read-only; creation already has explicit owners. Or
  converge duplicates deterministically, as triage buckets do.

### DI-5. Creating the managed One True Playlist is not idempotent after a partial failure
- Severity: low. Confidence: likely.
- Location: `Overplay/Services/PlaylistSyncService.swift:371-403`,
  `Overplay/Services/PendingOneTruePlaylistService.swift:52-69`.
- What: once `createPlaylist` succeeds, a later throw loses the new playlist's
  identity and leaves the pending request set. The next confirmation creates
  another "Overplay" playlist. MusicKit cannot delete the orphan.
- Fix: persist the created ID on failure and try to link it before creating
  again, or surface the rebuild-style "leftover playlist" message.

### DI-6. Any non-song entry in the One True Playlist blocks every removal
- Severity: low. Confidence: confirmed.
- Location: `Overplay/Services/OneTruePlaylistRemoteMembership.swift:149-150`, `:165`.
- What: `references(for:matching:)` returns nil when any iCloud entry is not a
  song, which the caller reads as "device copy differs" and defers.
- Trigger: one music video added to the playlist in the Music app. Every
  retirement afterwards reports "Apple Music will be updated after the next
  sync" and never is. The spec says rewrites retain videos in order.
- Fix: compare raw-ID occurrence counts first and carry non-song entries
  through untouched.

### DI-7. Two syncs of one playlist are not coalesced
- Severity: low. Confidence: likely.
- Location: `Overplay/Services/PlaylistSyncService.swift:45-58`, `:178-246`, `:638-654`.
- What: `activeSourceReads` counts readers but does not gate them. A manual
  Sync during a periodic cycle interleaves a second reconcile, and the older
  snapshot can be applied last, briefly removing a newly added Inbox song
  with a "Left … unplayed" history event. The next sync restores it.
- Fix: keep one in-flight task per playlist ID.

### DI-8. Two pagers return a truncated list as if complete
- Severity: low. Confidence: confirmed.
- Location: `Overplay/Services/LibraryBrowser.swift:196`,
  `Overplay/Services/MusicLibraryPagination.swift:16-19`.
- What: both stop silently on a repeated or unparseable `next` link. The sync
  pagers throw in the same situations. The effect is display and playback
  only, not membership.
- Fix: throw, as the sync pagers do.

## 3. Playback engine

`PlaybackController.swift`, everything in `Overplay/Playback/` and the
supporting services were read in full. No crash-class defect was found: the
slice has no `try!`, `fatalError`, `unowned`, checked continuations or
unguarded indexing. The intent is never cleared by an observation, error or
timeout, and the outgoing session is evaluated before the incoming state
replaces it. The findings are about what happens when a start, a recovery or
an observation overlaps something else.

None of the fixes below adds a retry, a confirmation loop or a queue
replacement.

### PB-1. A hung player call inside the observation path stops observation for the rest of the process
- Severity: medium. Confidence: confirmed ✔ for the mechanism; likely for the
  impact.
- Location: `Overplay/Playback/PlaybackPlayerObservation.swift:102-115`;
  `Overplay/Services/PlaybackController.swift:547-550,559-563` (inline
  `await repairUnpreparedQueue()`), `:2687-2688` (inline skip-on-reach),
  `:591-607` (sample loop).
- What: the observation's delivery task awaits the handler serially.
  `observePlayer()` awaits real player calls inline: the unprepared-queue
  repair (resolve, submit, `prepareToPlay`, load wait, play) and the
  skip-on-reach `skipToNextEntry()`, which has no stuck watchdog. If one of
  those never returns, which is the 2026-10-09 failure mode, the delivery task
  never completes and later invalidations only accumulate in `pending`. The
  repair runs precisely on queues whose prepare has already misbehaved. The
  sample loop has the same shape.
- Trigger: a repair's prepare hangs, and the network later returns and gets a
  fresh queue playing. From then on track changes are caught by the one-second
  sample only. Once paused there is no sampler, so a Play from the Lock Screen
  or the CarPlay transport is never observed: Overplay's UI and CarPlay lists
  stay "paused", listening is not counted, and stall detection is off until
  the app is foregrounded or an in-app command runs.
- Fix: keep `observePlayer()` free of awaited player calls. Start the repair
  in its own `Task` when `nowPlayingRepairPending` is consumed, and route the
  skip-on-reach call through `awaitPlayer` or its own task.
- Tests: none for a hang inside `observePlayer`.

### PB-2. A repeated tap during a start takes over the start hold
- Severity: medium. Confidence: confirmed ✔ for the code path; the audible
  result is likely.
- Location: `Overplay/Services/PlaybackController.swift:1200-1207` (select,
  `resumeCurrent`), `:1160-1171` (`PLAY-020` branch), `:1032-1041` (`play`,
  `startHold = nil`), `:1457-1472` (`startLoaded` early returns).
- What: `play(context:)` ends any start hold, by design for a real Play press.
  Two other actions route into it while the start they duplicate is still
  loading. Tapping the same song row again takes the `resumeCurrent` branch
  (the start already set `currentMember`), finds the player paused and calls
  `play`. Tapping Shuffle and Play again takes the `PLAY-020` branch, writes
  shuffle on the still-loading queue and calls `play`. In both, `play` clears
  the hold and calls `player.play()` before load has finished, and the
  original `startLoaded` then returns without its shuffle, skip or play.
- Trigger: tap Shuffle and Play, hear nothing for a second, tap again (common
  in the car). The interim first entry plays, with shuffle applied only to the
  entries loaded so far. Or double-tap a row: track 1 shows or plays until
  MusicKit reaches the start entry, which is the #58/#76 symptom the hold
  exists to prevent.
- Fix: in those two branches, return early when `isHoldingStart` is true. The
  start in flight is already doing what was asked and the hold is bounded at
  8 seconds. Keep the takeover for real Play presses.
- Tests: `playDuringAShuffledStartTakesOver` covers an explicit `play()` only.

### PB-3. A start that ends without playing is treated as success and clears the failure
- Severity: medium. Confidence: confirmed ✔.
- Location: `Overplay/Services/PlaybackController.swift:1409-1423` (`submit`),
  `:1434-1479` (`startLoaded`), `:806-813` (`playerAnswered`).
- What: `startLoaded` returns normally when it played, when the hold was taken
  by a Play press, and when the hold timed out. `submit` cannot tell these
  apart; whenever the generation matches it seeks, calls `clearFailure()` and
  clears `statusMessage`.
- Trigger: `prepareToPlay` takes 9 seconds. At 8 the stuck failure is shown
  and the hold ends. At 9 prepare succeeds and `submit` clears the failure,
  though nothing ever called `play()`. The CarPlay alert vanishes, the player
  is paused and there is no message. The same path can erase a failure set by
  a Play press that threw during the start, and the resume seek can land on
  whichever entry observation has since made current.
- Fix: have `startLoaded` report whether it reached `play()`; seek and clear
  only when it did.
- Tests: `StuckPlayerRecoveryTests.swift:194` asserts only that the kind is no
  longer `.stuck`.

### PB-4. Network-return recovery latches off after one hung attempt
- Severity: medium. Confidence: confirmed ✔.
- Location: `Overplay/Services/PlaybackController.swift:2054-2068`.
- What: `isRecoveringForNetworkReturn` is set, and reset in a `defer` that
  runs after `await recover(afterNetworkReturn: true)`. For a stuck player
  that recovery includes a `prepareToPlay` that can hang. The `defer` then
  never runs and every later `networkReturned()` exits at its first guard,
  with no log line.
- Trigger: the player is stuck. The user toggles mobile data, as the stuck
  message advises. The fresh queue's prepare hangs too. Toggling again does
  nothing until relaunch. The spec says one recovery per return.
- Fix: let the flag cover only the settle delay, which is what de-duplicates a
  burst of path updates, and reset it before `await recover(...)`.

### PB-5. Losing the queue while paused discards the resume position
- Severity: medium. Confidence: confirmed ✔ for the logic; the trigger
  (MusicKit dropping an idle queue) is likely but not device-verified.
- Location: `Overplay/Services/PlaybackController.swift:829-861`;
  `Overplay/UseCases/PlaybackSessionEvaluationService.swift:32`.
- What: `queueBecameEmpty` calls a session stale when its last observation is
  more than 5 seconds old. Paused players are not sampled, so any session
  paused for longer than that is stale. A stale, incomplete session takes the
  "queue played out" branch: the current member becomes the playlist's first
  song at 0:00 and the resume point is overwritten.
- Trigger: pause mid-playlist; the system later drops the idle queue or media
  services reset. On the next observation Now Playing jumps to the first song
  and Play restarts from the top. Had the process been killed instead,
  relaunch would have resumed at the saved song and position.
- Fix: when the outgoing session was paused, keep the member and position,
  force-save the resume point and return.

### PB-6. The foreground observation pass waits behind an unbounded library query
- Severity: low. Confidence: confirmed for the ordering.
- Location: `Overplay/OverplayApp.swift:128-141`;
  `Overplay/Services/PlaybackReconciliationService.swift:175-187`;
  `Overplay/Services/MusicKitLibraryPlaybackHistoryFetcher.swift:142-158`.
- What: on becoming active, statistics reconciliation (a `MusicLibraryRequest`
  with no timeout) is awaited before `reconcilePlayerState`, the pass that
  un-stales play state and modes. This is counting gating display, which the
  product priorities rule out. It also runs while a playback failure is
  active.
- Fix: run `reconcilePlayerState` first; skip the library query while a
  failure is showing.

### PB-7. Pause does not cancel a start that is still resolving tracks
- Severity: low. Confidence: confirmed; whether it is wanted is a product
  call.
- Location: `Overplay/Services/PlaybackController.swift:1054-1061,1274-1278,1348`.
- Trigger: playlist A is playing; tap a song in cold-cache playlist B on a
  weak signal; tap Pause. A pauses, and seconds later B starts.
- Fix, if unwanted: bump `startGeneration` in `pause()`.

### PB-8. A database reset does not supersede an in-flight start
- Severity: low. Confidence: confirmed by reading; rare.
- Location: `Overplay/Services/PlaybackController.swift:483-504`.
- What: `clearLocalStateAfterDatabaseReset` leaves `startGeneration`,
  `startHold` and several transient fields alone, so a start resolving at that
  moment installs and plays an intent built from deleted records.

### PB-9. Every playlist start does N single-row fetches and about 3N decodes on the main actor
- Severity: medium (estimated, not measured). Confidence: confirmed for the
  path.
- Location: `Overplay/Services/PlaybackController.swift:1336-1339,1526-1534,1554-1556`;
  `Overplay/Services/DevicePlaybackCache.swift:87-92,107,191`;
  `Overplay/Services/PlaybackQueueBuilder.swift:49-62`.
- What: `resubmit` (Play after every relaunch, recovery, the selection
  fallback, the repair) fetches one track per intent member, where
  `startPlayback` uses one batched fetch. `DevicePlaybackCache.prepare`
  decodes each cached track twice, and `resolvePlayableTracks` a third time
  with a new decoder each. On a cold launch each read is also a synchronous
  file read.
- Effect: Play after a relaunch on a 500-song playlist is about 500 fetches,
  1,500 decodes and 500 file reads on the main actor before the first MusicKit
  call, on the cold CarPlay start the spec cares most about.
- Fix: use `tracks(ids:)` in `resubmit`; keep the decoded `Track` beside its
  data in the cache; compute `uncached` once.

### PB-10. Collection starts rewrite every track file on each tap
- Severity: medium (estimated). Confidence: confirmed for the path.
- Location: `Overplay/Services/PlaybackController.swift:1649-1651,1738-1757,1769-1800`;
  `Overplay/Services/DevicePlaybackCache.swift:47-56`.
- What: `playCollection` encodes and atomically writes every passed track
  before the select-in-place check, so tapping another song in a 300-song
  library playlist that is already playing does 300 writes on the main actor
  first. A new start adds 300 decodes and up to 600 fetches.
- Fix: move the cache fill after the select-in-place branch and write only
  keys not already cached, as `collectionPlayable` does.

### PB-11. Engine maintainability
- Three overlapping mechanisms track a start: `startGeneration`, `startHold`
  and the `startsInFlight` tokens, plus `PlayerCallOutcome`. PB-2 and PB-3
  both come from that seam. A single "start attempt" value that reports its
  outcome (played, superseded, timed out) would remove the ambiguity.
- `togglePlayPause` and `performPrimaryPlaybackAction` (`:1066-1080`) are two
  play/pause toggles with slightly different conditions; only one has the
  default-playlist fallback. They should be one shared action (see also PA-6).
- The 2,934-line file also holds curation, undo, manual add, duplicate merge
  and rebuild (roughly `:1802-1952` and `:2204-2652`). They touch playback
  only through `settleSessionBeforeMoving`, `rekeyIntent` and
  `reconcileTrackMembership`, which is the cleanest seam if the file is split.
- `isBackward` (`:818-827`) builds full entry snapshots for the whole queue,
  with an artwork URL each, on every track change, to compare IDs.
- `networkReturned` and `startLoaded` call `Task.sleep` directly rather than
  the injected sleep, which forces real-time waits in tests (TST-8).
- Unused in production: `stopMonitoring()`, `canSkipTracks`,
  `isDeliveryStalled`, `PlaybackIntent.index(of:)`,
  `PlaybackSessionEvaluationService.markEvaluatedWithoutSkip`,
  `DevicePlaybackCache.loadLibrarySong`. `queueBecameEmpty(status:)` never
  reads its parameter.

### Worth one device check
Whether the `MPRemoteCommand` handlers in
`Overplay/Services/SystemNowPlayingBridge.swift:92-103` are always invoked on
the main thread could not be settled from code. If they are not, Swift 6's
isolation check would trap. Try it once with CarPlay MiniPlayer Controls on.

## 4. Cross-surface parity

AGENTS.md requires equivalent actions on every surface to go through one
shared entry point. Row selection, Shuffle and Play, Recents, Library,
Play Album/Artist, shuffle and repeat toggles, and the menu-bar transport all
do. These are the exceptions found.

### PA-1. The dashboard Play button makes its own resume decision
- Severity: medium. Confidence: confirmed ✔.
- Location: `Overplay/Views/DashboardView.swift:238-246` against
  `Overplay/Services/PlaybackController.swift:1150-1175`.
- What: the view calls `play(context:)` when the playlist is the current
  context and `playPlaylist(_:scope:…)` otherwise. `playPlaylist` already
  contains that decision, including `PLAY-020` (turn shuffle on if it is off).
  CarPlay (`CarPlayCoordinator.swift:931`), Siri (`VoiceActions.swift:42`) and
  the playlist screen (`PlaylistManagementViewModel.swift:284`) call it
  unconditionally.
- Effect: with the One True Playlist paused and shuffle off, the dashboard
  resumes unshuffled while the other surfaces turn shuffle on. The view's
  test (`currentTrack` based) also differs from the controller's (`intent`
  based), so after a relaunch the same button takes the other branch.
- Fix: call `playPlaylist` unconditionally and add a test through that entry
  point for "paused, same intent, shuffle off". If plain resume is what this
  button should do, put that in the controller and the spec.

### PA-2. CarPlay Promote, Retire and Restore discard the outcome
- Severity: medium. Confidence: confirmed.
- Location: `Overplay/CarPlaySupport/CarPlayCoordinator.swift:1241-1263`, `1328-1333`.
- What: the returned `CurationOutcome` (and the `Bool` from `restoreCurrent`)
  is dropped. The phone shows a toast from `statusMessage` and Siri speaks it;
  CarPlay shows nothing.
- Effect: Promote in the car when the Apple Music write fails. The button
  appears to do nothing, on the surface the spec treats as primary.
- Fix: on `.failed` (and probably `.unavailable`) call `showError`. Also wrap
  these three calls in `MusicKitActivityLog.shared.withOrigin(.carPlay)`, as
  every other CarPlay action is.

### PA-3. CarPlay enables curation buttons on a different rule from the app
- Severity: low. Confidence: likely.
- Location: `Overplay/CarPlaySupport/CarPlayCoordinator.swift:1173-1178` against
  `Overplay/Views/NowPlaying/NowPlayingComponents.swift:399-415` and
  `Overplay/App/Shell/SplitAppShell.swift:488-507`.
- What: the app and the Mac menu disable on `currentMember == nil`. CarPlay
  enables on `hasCurrentTrack && playlistRole != nil`, which is true before
  attribution after a relaunch. The tap then fails its guard and, per PA-2,
  says nothing.
- Fix: one shared helper beside `CarPlayNowPlayingActionPolicy`, used by all
  three call sites.

### PA-4. CarPlay Add can report failure after a successful add
- Severity: low. Confidence: confirmed.
- Location: `Overplay/CarPlaySupport/CarPlayCoordinator.swift:1265-1278`.
- What: success is inferred after the await from `canAddCurrentToOverplay`,
  which describes whichever song is current by then.
- Fix: return a result from `addCurrentToTriage` / `addCurrentToOneTruePlaylist`,
  as `promoteCurrent` does.

### PA-5. Menu commands and shortcuts are dead in the compact shell
- Severity: low. Confidence: confirmed.
- Location: `Overplay/App/Shell/SplitAppShell.swift:208`,
  `Overplay/App/Shell/CompactAppShell.swift`, `Overplay/App/OverplayCommands.swift:35-41,79-106`.
- What: only `SplitAppShell` publishes `shellCommands`. On an iPad in Slide
  Over or a narrow split, or an iPhone with a keyboard, Play/Pause, Next,
  Previous, Promote, Retire and ⌘, do nothing.
- Fix: publish the transport and song-move commands from a small modifier
  both shells use.

### PA-6. CarPlay primary Play calls a different entry from the app's primary button
- Severity: not judged. Confidence: confirmed as a difference only.
- Location: `Overplay/CarPlaySupport/CarPlayCoordinator.swift:943` calls
  `play(context:)`; the app calls `performPrimaryPlaybackAction`
  (`SplitAppShell.swift:466`, `PlaybackControlsView.swift:78`).
- What: this was noticed while mapping test coverage and not traced to a
  behavioural difference. It is worth a look given the parity rule.

## 5. Other correctness

### CO-1. The save-notification filter compares typealias names
- Severity: medium. Confidence: likely ✔ (the names in code are confirmed; the
  runtime entity names are inferred from the `@Model` class names).
- Location: `Overplay/Presentation/LibraryPresentationChange.swift:32-40`;
  consumers at `Overplay/Services/PlaylistCollageService.swift:26` and
  `Overplay/CarPlaySupport/CarPlayCoordinator.swift:988`.
- What: the filter tests for `"PlaylistRecord"`, `"PlaylistItemRecord"`,
  `"TrackRecord"` and `"ApplePlayCountRecord"`. Those are typealiases. The
  model classes are `LibraryPlaylistV2`, `LibraryMembershipV2`,
  `LibraryTrackV2` and `LibraryAppleCountV2`, so
  `PersistentIdentifier.entityName` should never match. Only
  `RecentCollectionRecord` does.
- Effect: when a save notification carries identifiers, collage maintenance
  does not run after a sync and CarPlay's persistence-driven refresh fires
  only for Recents. When it carries none, every save refreshes. The filter is
  wrong either way. `LibraryPresentationChangeTests` builds identifiers with
  synthetic names, so it cannot catch this.
- Fix: compare against `Schema.entityName(for:)` and add a test that feeds a
  real notification from an in-memory container.

### CO-2. `LibraryCategoryView` keeps state when the sidebar swaps categories
- Severity: medium. Confidence: likely ✔ (follows from the in-place swap
  recorded in `docs/SIDEBAR_NAVIGATION_NOTES.md`; not run).
- Location: `Overplay/Views/Library/LibraryCategoryView.swift:10-11,43`;
  host `Overplay/App/Shell/AppShellDestinationView.swift:47-52`.
- What: Playlists, Albums and Artists resolve to the same view with no `.id`.
  It loads with `.task { await cache.prepare(category) }` (no id) and owns the
  filter state. The notes say an in-place swap fires `.task(id:)` but not
  `onAppear`. `PlaylistManagementView` already guards against this.
- Effect: on iPad or Mac, open Albums then choose Artists. `prepare(.artists)`
  never runs, so an unloaded category shows "Loading…" indefinitely, and an
  open filter carries over.
- Fix: `.task(id: category)` plus `.id(category)`. `MadeForYouPlaylistView`
  (`MadeForYouViews.swift:94-102`) has the same shape and may show one mix's
  songs under another.

### CO-3. Siri waits 8 seconds and gives the wrong reason when the library can never be ready
- Severity: medium. Confidence: confirmed.
- Location: `Overplay/App/AppRuntime.swift:134-148`,
  `Overplay/Intents/OverplayIntents.swift:18-20,28-30`.
- What: the wait loop exits on ready, on a preparation error, or at the
  deadline. Not authorised, setup unfinished and restoring-from-cloud set none
  of those.
- Effect: "Play Overplay" on a phone where setup was never finished. Siri is
  silent for 8 seconds, then says "Overplay is still restoring your library".
- Fix: break early on those states with a specific message for each.

### CO-4. Search results can be overwritten by an older request
- Severity: low. Confidence: confirmed.
- Location: `Overplay/Views/SearchMusicView.swift:30,76`,
  `Overplay/ViewModels/SearchMusicViewModel.swift:42-46`,
  `Overplay/Services/SearchService.swift:26-64`.
- What: each submit or clear starts an unstructured `Task` with no
  cancellation or generation check. The last response to land wins, and its
  `defer` clears the spinner.
- Fix: a generation counter in `SearchService.search`, or keep and cancel one
  task.

### CO-5. Row "starting" highlight is cleared by an earlier tap
- Severity: low. Confidence: confirmed.
- Location: `Overplay/Views/PlaylistManagementView.swift:294-299`,
  `Overplay/Views/CollectionSongListView.swift:71-76`,
  `Overplay/Views/SearchMusicView.swift:94-99`.
- Fix: `if startingRowID == row.id { startingRowID = nil }` at all three.

### CO-6. A cache manifest that fails to decode never recovers
- Severity: low. Confidence: confirmed.
- Location: `Overplay/Services/ArtworkCacheService.swift:577-597`,
  `Overplay/Services/AlbumArtworkThemeStore.swift:136-151`.
- What: both loaders throw on a decode error and leave the cached value nil,
  so every later call re-reads and throws. A build that adds a non-optional
  field makes all artwork disappear until the system purges Caches.
- Fix: start from an empty value on decode failure and add a corrupt-file
  test.

### CO-7. Intermediate CarPlay lists are not refreshed when returned to
- Severity: low. Confidence: confirmed.
- Location: `Overplay/CarPlaySupport/CarPlayCoordinator.swift:1340-1390`, `1418-1423`.
- What: `refreshLibraryLists` updates the root and the top list only. Going
  back to an Albums list still marks the previously playing album until the
  next track change.
- Fix: in `templateWillAppear`, update a tracked list template.

### CO-8. Background work runs with no background-task assertion, wake scheduled last
- Severity: low (counting only). Confidence: likely.
- Location: `Overplay/OverplayApp.swift:84-88,105-132`.
- What: on `.background` two disk flushes are awaited before the BGAppRefresh
  request is submitted and the reconciliation waypoint captured. A slow flush
  can mean suspension before either runs.
- Fix: do the cheap synchronous steps first, or wrap the block in
  `beginBackgroundTask`.

### CO-9. Smaller items
- `CarPlayCoordinator.disconnect()` neither cancels `failureAlertCheck` nor
  clears `alertedFailureKind` and `failureAlert` (`:203-232`).
- `playCollection` pops "whatever is on top" after an await of unbounded
  length, which can pop the wrong list if the driver backed out meanwhile
  (`:1314-1321`).
- `CarPlaySceneDelegate.sceneDidDisconnect()` takes no parameter, so it is not
  the delegate method and is never called (`CarPlaySceneDelegate.swift:21-25`).
- `AlbumArtworkThemeStore.theme(for:accessedAt:)` ignores its date, so pruning
  is by generation date rather than last use (`:57-69,161-169`). It only
  matters past 10,000 entries.
- `LibrarySongsView.reloadKey` is keyed on the entry count, so a refresh that
  changes songs but not the count leaves rows stale; a tap on a stale row then
  plays 100 random songs (`LibrarySongsView.swift:66-68`).

## 6. Performance

None of this was measured. The common thread is whole-table SwiftData work on
the main actor that grows with library size, and fetches reached from view
bodies.

### Main actor and SwiftData

**PF-1. Every new track lookup can scan the whole track table.** Medium,
confirmed ✔. `Overplay/Persistence/TrackRecordRepository.swift:33-68`. When
the predicate lookups miss, which is the normal case for a song not yet
stored, `track(catalogID:libraryID:)` falls back to a sorted fetch of every
track and checks `confirmedAliases` per row. Reconcile calls it once per
snapshot (`PlaylistSyncService.swift:538,680`), so a first import of N songs
does about N full-table fetches of a growing table. Fix: build one alias index
per sync pass and pass it in.

**PF-2. Hot lookup columns have no index.** Low, confirmed. Memberships
(`trackID`, `playlistID`), tracks (`id`, `catalogID`, `libraryID`) and history
(`trackID`, `playlistID`) declare no `#Index`, though three other models do
and every repository lookup filters on these columns. Related whole-table
passes: `mergeOtherItems` (`PlaylistItemRepository.swift:349-356`),
`TrackOwnershipMigrationService.migrate` on every merge pass with an
unconditional save, and every reconcile's provenance rewrite
(`PlaylistSyncService.swift:616-621,626`).

**PF-3. CarPlay list refresh does a full library read plus a fetch per row at
every track change.** Medium, confirmed for the path.
`Overplay/CarPlaySupport/CarPlayCoordinator.swift:727-743,823-857,1340-1390`.
`refreshLibraryLists` runs 100 ms after every observed playback change. It
rebuilds root summaries from all items and tracks, rebuilds the visible
playlist, and `isCurrentTrack` does a single-row fetch per displayed row
before the cheap guard. Fix: resolve the current track once per refresh; skip
the root rebuild when only a count changed.

**PF-4. Now Playing reads playback time at the top of the pane.** Medium,
confirmed ✔. `Overplay/Views/NowPlaying/NowPlayingPaneView.swift:30-34`,
`MiniPlayerLozengeView.swift:134-139`, `MiniPlayerToolbarView.swift:106-111`,
`Overplay/Presentation/NowPlayingPresentationFactory.swift:43-82`. The factory
reads `elapsedSeconds`, which changes every second, and makes four fetches for
counts and state. So the whole pane body re-runs each second with four
fetches (eight with the full player open), feeding a bar that already
interpolates itself. Fix: let a small leaf view read elapsed time; build
title, artist and counts from values that do not depend on it; fetch the
displayed item once.

**PF-5. Now Playing action buttons run about 27 fetches per body pass.**
Medium, confirmed ✔. `Overplay/Views/NowPlaying/NowPlayingComponents.swift:370-382`.
`actions` is a computed property doing three fetches, and `circleSide` reads
it twice per button. The body re-runs on every width change, so a sidebar
animation or window resize pays this per frame. Fix: compute `actions` once
per body pass.

**PF-6. Menu-bar song moves fetch on every `SplitAppShell` body pass.** Low,
confirmed. `Overplay/App/Shell/SplitAppShell.swift:208,460-509`.
`shellCommands` is rebuilt in `body` with three or four fetches, and the body
re-runs per frame of a sidebar drag. Fix: derive availability from observed
controller state, or compute inside the command closures.

**PF-7. Collection song lists refetch the whole library on each metadata
bump.** Medium, confirmed.
`Overplay/Presentation/RecentCollectionPresentation.swift:41-59` and five
callers. With a 25-result search or a 12-song album open, every track change
fetches all tracks, items and playlists on the main actor. Fix: fetch by
predicate for small inputs.

**PF-8. Restoration check materialises whole tables every launch.** Medium,
confirmed. `Overplay/Persistence/LibraryRestorationService.swift:53-85,117-123`.
It fetches every track, item and playlist before `isReady`, and every 500 ms
while waiting. This sits inside Siri's 8-second budget and a cold CarPlay
launch. Fix: accept on the cheap checks when the local receipt matches.

**PF-9. Video cleanup decodes every track's playback data on each sync and
launch.** Medium, confirmed for control flow.
`Overplay/Persistence/VideoTrackCleanupService.swift:40-49,95-97`. Each call
JSON-decodes a MusicKit `Track` per stored track, and
`DevicePlaybackCache.data(for:)` keeps every payload in a dictionary with no
eviction. After the first sync the whole playback cache is resident for the
life of the process. Fix: scan once per launch at most, without populating
the shared cache.

**PF-10. Play-count refresh scans the library many times; one loop is
quadratic.** Low, confirmed for scan counts.
`Overplay/Services/ApplePlayCountSyncService.swift:88-134,187-229,301-307,353-373`.
Fix: skip `persist([])`, group items by track once, wrap the loop in one
`withSnapshot`.

**PF-11. Smaller view-layer costs.**
- `TriageSourcesView` holds an unfiltered `@Query` over every playlist item to
  print one count per source (`TriageSourcesView.swift:13,168-171`).
- `PlaylistManagementView`'s memo key reads every item and track on every body
  pass, including each filter keystroke (`:73,118,184-190,260-269`).
- `LibrarySongsView` re-maps the whole library per property access (`:23,35,49-58`).
- Fetches from `body` in `SettingsView.swift:377-379`,
  `PlaybackControlsView.swift:63-71` and `PlayingFromView.swift:35-58`.
- Regexes are constructed per track row body
  (`PlaylistTrackRowView.swift:49-60`, `TrackTextVariants.swift:25-34`).
- The progress bar rebuilds its glass capsule 30 times a second
  (`NowPlayingComponents.swift:187-227`).
- Device motion runs at 30 Hz with no scene-phase check and no threshold
  (`PlayerGlassBackground.swift:170-199,225-235`).

### Apple Music request volume

These matter beyond speed: `LOAD-001` and the Apple Music system-failure
investigation both treat request load as a reliability concern.

**PF-12. Song resolution issues one MusicKit request per song, twice.**
Medium, confirmed. `Overplay/Services/MusicLibrarySongResolver.swift:96-106,129-137`.
A 1,000-song playlist costs 1,000 library queries per full sync. Catalog
sources never record a change fingerprint, so each linked mix repeats this
every 30-minute cycle. Fix: batch with `memberOf:` in chunks of 100, as
`PlaybackCollection.songs(ids:)` does.

**PF-13. Web library paging probably drops to 25 per page after the first.**
Medium, likely. `Overplay/Services/AppleMusicLibraryPlaylistResources.swift:25,40-43,134,151-154`,
`Overplay/Services/LibraryBrowser.swift:193-207`. `limit=100` is set on the
first URL only; later pages follow `next` verbatim. `addUnlessPresent` pages
the whole One True Playlist before each promotion, including from CarPlay:
about 37 requests for 1,000 songs if the limit is dropped. One logged `next`
URL would settle it. Fix: re-append the limit; consider a short-lived cache of
the cloud entries.

**PF-14. The focused play-count lookup pages whole playlists at track start.**
Medium, confirmed for the path.
`Overplay/Services/ApplePlayCountSyncService.swift:176-177,244-284`; trigger
`PlaybackController.swift:2767-2785`. `refreshCurrentTrack` also loads every
entry of each source playlist, gated only by a 60-second limiter, while
playing. Fix: drop `refreshPlaylistCounts` from the current-track path.

### Artwork and memory

**PF-15. Pile collage loads every distinct cover at 512 px, past the cache
budget.** Medium, likely. `Overplay/Models/PlaylistCollage.swift:91-147`,
`Overplay/Services/PlaylistCollageService.swift:142-193`. The disk cache keeps
32 MiB of 512 px variants, roughly 400–600 covers by estimate. A larger
playlist re-downloads most covers daily (the arrangement changes every 24
hours), on cellular too, to draw covers that are almost all hidden. A
transient failure caches nothing, so every appearance re-runs the composition.
Fix: cap pile placements or draw lower layers from the 128 px variant.

**PF-16. Artwork manifest bookkeeping is O(entries) per access.** Low,
confirmed. `Overplay/Services/ArtworkCacheService.swift:392-412,518-548,599-604`.
`withManifest` forces a full dictionary copy; each access schedules a
pretty-printed re-encode; memory hits await `recordAccess` before returning.

**PF-17. `TrackRecord.musicKitPlaybackData` hides synchronous file I/O.** Low,
confirmed. `Overplay/Models/TrackRecord.swift:40-43,68`. The setter writes a
file with no equality check, and `init` always assigns, costing a `removeItem`
per new record.

**PF-18. Apple play-count evidence is append-only and decoded eagerly.** Low,
likely. `Overplay/Persistence/ApplePlayCountRepository.swift:35-53`. Each state
change inserts a row; nothing compacts them; every row is JSON-decoded when a
presentation is built.

## 7. Apple API usage

### API-1. Promoting a library-only song sends its library ID to the catalog
- Severity: medium. Confidence: confirmed ✔.
- Location: `Overplay/Services/PlaylistMutationService.swift:266-284`.
- What: `add(track:to:)` uses `track.catalogID ?? track.libraryID` in a
  `MusicCatalogResourceRequest<Song>`. A library ID finds nothing there.
  Tracks legitimately lack a catalog ID (uploads, matched songs).
- Effect: promoting such a song always fails with "This track does not have
  an Apple Music identifier Overplay can add".
- Fix: when only a library ID exists, fetch with `MusicLibraryRequest<Song>`.

### API-2. Rebuild asks the catalog for every missing song in one request
- Severity: medium. Confidence: likely.
- Location: `Overplay/Services/OneTruePlaylistRebuildService.swift:69-84`.
- What: elsewhere these are chunked at 100. "Make It Again" after the playlist
  was deleted in Music is exactly the path that takes this branch, and with a
  large playlist the single request can fail or truncate.
- Fix: reuse `PlaybackCollection.songs(ids:)`.

### API-3. No push entitlement although `remote-notification` is declared
- Severity: medium if absent from the signed app. Confidence: speculative ✔
  (no `aps-environment` anywhere in the repo; automatic signing may or may not
  inject it).
- Location: `Overplay/Overplay.entitlements`,
  `Overplay/Overplay-MacCatalyst.entitlements`, `Config/Info*.plist:56`.
- Effect if missing: CloudKit sends no silent pushes, so a promote on the Mac
  reaches the phone only at next launch or foreground.
- Check: `codesign -d --entitlements -` on a signed build. Add to TODO 1.5.

### API-4. Private AppKit access and responder-chain hacks
`MacStaticNavigation` (replacing SwiftUI's navigation delegate),
`SplitViewSwipeSwitch`, `MacSinglePlayerWindow` and `MacAppKitWindow` all
depend on UIKit/AppKit internals. They are documented in place, and most fail
soft (CR-2 does not). None has a test or a runtime log to notice when an OS
update breaks it.

### Checked and fine
Every `CPListItem` handler calls its completion on all paths. List updates use
`updateSections`; `setRootTemplate` is called only at connect and when an
opened playlist is gone. Template depth stays within five. App Intent phrases
all contain the application name, `perform` is main-actor, and the model
container exists on a cold background launch. The `BGTaskScheduler` identifier
matches the plist and is registered in `App.init`. Photos uses add-only
authorisation. No deprecated SwiftUI API was found in the view layer.

## 8. Concurrency

Swift 6 mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` does most of the
work here. There is one `@unchecked Sendable`
(`ArtworkImagePipeline.swift:4`, a decoded image), one `nonisolated(unsafe)`
(`MacStaticNavigation.swift:63`, main-thread in practice), and eleven
`Task.detached`, all for off-main CPU or I/O.

### CC-1. Model objects held across awaits with only `isDeleted` as a guard
- Severity: low. Confidence: speculative.
- Location: `Overplay/Services/TrackIdentityMergeService.swift:36-40,105`,
  `Overplay/Services/ApplePlayCountSyncService.swift:356-371`,
  `Overplay/Services/DuplicateTrackService.swift:170-188`.
- What: `mergeDuplicates` yields while grouping and nothing stops two runs
  overlapping. `persist` keeps items across a yield and filters on
  `!isDeleted`, which may not be reliable after a delete has been saved.
- Fix: an in-flight flag on `mergeDuplicates`; re-fetch by ID after a yield.

### CC-2. Unsequenced unstructured tasks
The search race (CO-4), overlapping syncs (DI-7), the stale removal set (DI-1)
and the row highlight (CO-5) are all the same shape: state captured before an
await and trusted after it. DI-1 is the only one with a lasting effect.

### CC-3. Warm-up enqueue can queue a key twice
`AlbumArtworkThemeWarmupService.swift:70-81` awaits between its check and its
insert. Harmless, because the provider coalesces.

## 9. Release readiness, configuration and privacy

### REL-1. Diagnostics testers are told to use are compiled out of Release
- Severity: high for the first TestFlight build. Confidence: confirmed ✔ for
  the `#if DEBUG` gating and the reminder text; the scheme setting and TODO
  wording are as reported by the review.
- Location: `Overplay/Views/SettingsView.swift:297-353` (iOS) and `:682-725`
  (Mac); `Overplay/Presentation/SysdiagnoseReminder.swift:39,46`;
  `docs/TODO.md` item 1.6 and Milestone 4; `README.md:239-276`;
  `docs/OVERPLAY_DESIGN_SPEC.md:2698-2700`.
- What: Apple Music Call Activity, Full Activity Report, Share Activity Log,
  Clear Recorded Activity and Run MusicKit Diagnostics are all inside
  `#if DEBUG`. Both shared schemes archive with Release. The spec says Release
  leaves them out; TODO 1.6 says "Keep them for TestFlight, where they are how
  testers report stalls". The log itself is still recorded in Release.
- Effect: a tester with a stuck player follows the in-app sysdiagnose steps
  ("Share it with Overplay's activity log from Settings → Apple Music Call
  Activity") and finds no such section. The evidence the stall investigation
  (#90) depends on cannot be exported.
- Fix: decide the intent. If testers need it, gate on a runtime flag or a
  Troubleshooting row instead of `DEBUG` and update the spec. Otherwise fix
  the TODO, the README and the reminder text.

### REL-2. Developer documents ship inside the app bundle
- Severity: low. Confidence: confirmed ✔ for `AGENTS.md` and `docs/TODO.md`;
  likely for the CarPlay README.
- Location: `Overplay.xcodeproj/project.pbxproj:10-11,245-246`;
  `Overplay/CarPlaySupport/README-CarPlay.md` sits in the synchronized group.
- What: the roadmap, with issue numbers and known defects, is copied into the
  `.app`.
- Fix: remove the two build-file entries; add a membership exception for the
  README or move it to `docs/`.

### REL-3. Diagnostics write artwork URLs and track titles to public logs
- Severity: medium. Confidence: likely.
- Location: `Overplay/Services/MusicKitActivity.swift:358-366`,
  `Overplay/Services/ArtworkCacheService.swift:249`,
  `Overplay/Services/MusicKitActivityLog.swift:517-545`,
  `Overplay/Services/MusicKitDiagnosticsService.swift:205-212`.
- What: a failed artwork download records `String(reflecting: error)` plus
  each underlying error's `userInfo`, which should include the failing URL.
  For uploaded-library covers that is the pre-signed URL the code avoids
  logging elsewhere. The string goes to the launch log and to the unified log
  as `.public`, alongside `detail` strings that carry track titles.
- Effect: a shared activity log or sysdiagnose contains listening history and
  day-valid signed URLs.
- Fix: strip the query from URL keys; log `detail` and `chain` as private or
  drop titles before release.

### REL-4. Activity logs are included in backups
- Severity: low. Confidence: confirmed.
- Location: `Overplay/Services/MusicKitActivityLog.swift:123-135,373-407`.
- What: up to ten 5 MB launch logs live in Application Support with no
  `isExcludedFromBackup`. The snapshot is re-encoded in full every 5 seconds
  when dirty, and flushed synchronously on the main thread at backgrounding.
- Fix: exclude the diagnostics directory from backup; flush off the main
  thread.

### REL-5. Build-setting inconsistencies
- `MACOSX_DEPLOYMENT_TARGET = 26.2` at project level (`project.pbxproj:357,416,603` ✔);
  docs say 26.4. Probably inert for Catalyst, but misleading.
- Project-level Release has no `VALIDATE_PRODUCT = YES`.
- `OverplayUITests` lacks `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- `OVERPLAY_FIRST_RUN` is set only on the command line.
- No warnings-as-errors setting anywhere.
- The owner's real bundle ID is hard-coded at
  `Overplay/Persistence/AppPersistence.swift:56,75`, while `Shared.xcconfig`
  uses `com.example`.
- Six `UserDefaults.standard` uses (`ApplePlayCountRepository:89,91`,
  `ListenLedger:36,38`, `MadeForYouLibrary:44,65`) bypass
  `AppPersistence.libraryDefaults`, so the first-run build shares its device
  ID and Made For You cache with the everyday build.

### REL-6. Already tracked in TODO and still open
No `PrivacyInfo.xcprivacy` (1.2); `ITSAppUsesNonExemptEncryption` absent
(1.5); `MARKETING_VERSION` mismatch (1.5).

### Repo hygiene
No secrets, team IDs or build output are tracked; `Config/Local.xcconfig` is
ignored ✔. `.gitignore` lacks `.DS_Store`, `.claude/`, `DerivedData/` and
`*.xcresult` (covered only by a machine-global ignore).
`Diagnostics/MusicIdentityProbe/observed-responses.txt` is a dump from a real
library with persistent IDs and titles. `IdentityProbeApp.swift` belongs to no
target, so nothing compiles it.

## 10. Tests and tooling

1,079 `@Test` declarations. No disabled tests, no XCTest in the unit target,
no real MusicKit or network, in-memory SwiftData throughout. The fake player
has all five capabilities AGENTS.md demands. The gaps are in what the tests
can reach.

### TST-1. `CarPlayCoordinator` has no test references
- Severity: high (coverage). Confidence: confirmed.
- What: the leaf pieces are tested (renderer, snapshot, action policy). The
  coordinator, where CarPlay decides which shared entry point to call, is not.
  AGENTS.md requires regression coverage to "check adapter routing". PA-1 to
  PA-6 are the kind of divergence that currently passes all tests.
- Fix: extract the row-to-action mapping into a small pure function and test
  that each CarPlay row resolves to the same controller call as the app.

### TST-2. Unit tests can only run in the iOS simulator
- Severity: medium. Confidence: confirmed.
- Location: `Overplay.xcodeproj/project.pbxproj:494-549,649-676`.
- What: the test targets do not support Mac Catalyst. None of the 20
  `targetEnvironment(macCatalyst)` sites is compiled in a test run, although
  AGENTS.md makes My Mac the default verification destination. Every
  `targetEnvironment(simulator)` branch is the one under test, so the real
  bodies of `MusicAuthorizationService` are never compiled into a test build
  and `AlbumArtworkThemeTests` never runs the text-recognition path.
- Fix: add `SUPPORTS_MACCATALYST = YES` to `OverplayTests` so pure-logic
  suites can run on the Mac.

### TST-3. `PlaybackAttribution` (PLAY-012) has no direct tests
- Severity: medium. Confidence: confirmed for no direct references.
- Location: `Overplay/Playback/PlaybackAttribution.swift:30-78`.
- What: the fixture always makes unique titles and artists at 180 s, so the
  ambiguity branches look unexercised: an item matching several members, two
  members with the same normalised title and artist, a duration disagreement
  vetoing a match, text folding, empty fields, and a cached attribution
  corroborated by metadata only. This decides which song a play is counted
  against.
- Fix: one pure table test.

### TST-4. Failures the fake player cannot model
- Severity: medium. Confidence: confirmed.
- Location: `OverplayTests/PlaybackTestSupport.swift:14-260`.
- What: `selectEntry` can only throw `entryNotInQueue`, so the general failure
  branch at `PlaybackController.swift:1219-1223` is unreachable in tests.
  `skipToPreviousEntry` cannot fail. `pause()` always takes effect, so the
  2026-10-19 "pause ignored" incident cannot be modelled. Shuffle and repeat
  writes always take. `notify()` always sends queue and state together.
  `submitQueue` cannot fail. `reverseQueueOrder()` has no callers.
- Fix: add `selectFailure`, `previousFailuresRemaining`, `ignoresPause`,
  `ignoresModeWrites` and `notify(_ changes:)`.

### TST-5. Controller cases with no test
Confirmed by reference count; scenario gaps judged from test names.
- Selecting the current track while already playing (expect no command).
- An in-intent jump from a paused player, and one where `play()` fails after
  `selectEntry` succeeds.
- Zero references: `togglePlayPause`, `toggleRepeatAll`, `restoreCurrent`
  (on the CarPlay path), `moveCurrentToInbox`, `moveTrackToInbox`,
  `promoteTrack`, `moveRecentSong`, `resetAllLocalStats`,
  `clearLocalStateAfterDatabaseReset`, `mergeDuplicateTracks`,
  `reconcilePlaylistSelection`.
- Thin: `next` ×2, `previous` ×1, `toggleShuffle` ×1, `promoteCurrent` ×1,
  `evictCurrent` ×1.

### TST-6. Other untested types over 80 lines
`AlbumArtworkThemeProvider` (272), `LibraryCache` (201, already in TODO),
`SystemNowPlayingBridge` (162; its static `info(...)` is trivially testable),
`MusicAuthorizationService` (139), `OverplayIntents.swift` (129),
`AlbumArtworkThemeWarmupService` (128), `AudioOutputMonitor` (89). The
MusicKit boundary types (`ApplicationMusicPlaybackPlayer`, the two fetchers)
are reasonably untested.

### TST-7. The test host launches the whole app and shares its state
- Severity: medium. Confidence: likely (read, not run).
- Location: `Overplay/OverplayApp.swift:15-18,46-83`,
  `Overplay/App/AppRuntime.swift:23-31`,
  `OverplayTests/PlaybackTestSupport.swift:309,330-334`.
- What: under test the `WindowGroup` still builds `ContentView` and runs the
  startup bootstrap. `AppRuntime` and `OverplayApp` detect a test run
  differently. `PlaybackFixture` writes every fixture track into the real
  `DevicePlaybackCache.shared` directory and never removes them. Only three
  test files replace the activity log; the rest record into the shared one on
  disk. `.serialized` covers a suite only, and the scheme runs suites in
  parallel.
- Effect: no failure was seen, but this is the shape that produces
  order-dependent or parallel-only flakes.
- Fix: render an empty scene under test; inject a cache and log with no
  backing file through `PlaybackFixture`; use one detection helper.

### TST-8. Real-time waits
- Severity: medium. Confidence: confirmed.
- What: 26 `Task.sleep` and 18 `Task.yield` in tests. The controller's
  sampling sleep is injected, but `stuckCallLimit`, `startHoldLimit` and the
  CarPlay renderer's replay still run on the wall clock
  (`StuckPlayerRecoveryTests.swift:68,137,235,333,484`,
  `CarPlayListRendererTests.swift:177-335`). Several assertions are "sleep,
  then expect nothing happened", which cannot fail on a slow machine.
- Fix: inject a clock, as was done for sampling.

### TST-9. UI tests skip silently
Every UI test starts with `XCTSkipUnless(idiom == …)`, and `rotate(to:)`
throws a skip when the simulator will not rotate. A green UI run on one
destination may have exercised one test. Document the two required
destinations and treat an unexpected skip count as a failure.

### TST-10. Tooling
- No CI, no linter or formatter configuration, no hooks.
- `commands.check` in `.agent/config.yaml:6` ✔ runs the simulator tests
  without `-parallel-testing-enabled NO`, against the project's own serial
  rule. The schemes have parallel testing on and no test plan; code coverage
  is off.
- UI tests are in a separate scheme and not part of `check`.
- Fix: put the flag in `commands.check`, or commit a test plan with
  parallelisation off and coverage on. A build-only CI job plus the pure-logic
  suites would catch compile breaks.

## 11. Interface and accessibility

### UI-1. Tap targets under 44 pt
Low, likely (sizes read from code). `PlayingFromView.swift:17-28` (a caption
text button about 16 pt tall), `AudioOutputPillView.swift:11` (32 pt high),
compact Previous/Next at 34 pt (`PlaybackControlsView.swift:139-148`),
`ShuffleAndPlayButton.swift:14-21`, and the filter clear button
(`ListFilter.swift:90-97`). Fix with a larger hit shape, leaving the drawn
size alone.

### UI-2. Mini player transport draws glass on the bar's own glass
Low, speculative (structure confirmed, appearance not checked).
`MiniPlayerLozengeView.swift:44,109,125`. The Mac toolbar pill avoids this
explicitly; the iOS bar does not.

### UI-3. Row artwork is decoded at 128 px for 72 pt rows
Low, confirmed. There are two size buckets, 128 and 512, so 216 px rows are
upscaled about 1.7×. Add a 256 bucket or record it as a deliberate trade-off.

### UI-4. Views with no `#Preview`
AGENTS.md asks for one per view. Missing:
`NowPlaying/NowPlayingComponents.swift` (eight views),
`NowPlaying/ThemedPlayerHost.swift`, `NowPlaying/AlbumArtworkThemeDebugView.swift`,
`Library/LibraryCollectionView.swift`, and the screen-level
`MadeForYouPlaylistView`, `MadeForYouGridView` and `AddToPlaylistView`.

### UI-5. No string catalog
Low for a single-language pre-release. Plurals are hand-rolled in at least ten
places and sentences are assembled with `+`. If localisation is on the
roadmap, add a catalog; either way, the three copies of the "N songs" helper
could be one.

### Checked and fine
Icon-only buttons carry labels; colour-coded state has accessibility values;
sliders, the volume pill and the progress bar expose values; Reduce Motion and
Reduce Transparency are honoured in the player. Every long list is lazy with
stable identity. Artwork loading is cancellable, downsampled off the main
actor and coalesced. Each UIKit bridge has a stated reason.

## 12. Documentation and maintainability

### DOC-1. Docs that contradict the code
- The spec's `COUNT-001` row and its component section name
  `Overplay/Playback/ListeningSessionTracker.swift`, which does not exist ✔
  (`OVERPLAY_DESIGN_SPEC.md:108,2752-2754`).
- The spec and TODO describe a Mac title-bar mini player; commit `0a59f1f`
  moved it to the bottom and changed no docs
  (`OVERPLAY_DESIGN_SPEC.md:229-230,2546`; `TODO.md:35,210,364`).
- AGENTS.md says absolutely not to add `MPRemoteCommandCenter` handlers or
  write `MPNowPlayingInfoCenter`, but `PLAY-016` allows the default-off
  mirror that `SystemNowPlayingBridge` implements. AGENTS.md needs the
  carve-out. The option also has two names ("Mirror Now Playing from
  Overplay" and "CarPlay MiniPlayer Controls").
- `Overplay/CarPlaySupport/README-CarPlay.md` describes a Shuffle that
  contradicts `PLAY-020`; the spec's CarPlay section still describes a header
  Shuffle button and "no shuffle rows".
- The spec says sync "may heal the linked `musicPlaylistID`" by name; no code
  does.
- The spec says the decoded-image budget is a shared 24 MiB; the code uses
  64 MiB plus a separate 24 MiB collage cache.
- TODO's "905 tests" is stale (1,079 now).
- The README does not mention the MIT licence.

Requirement IDs are otherwise consistent: every ID referenced in code and
tests exists in the spec's index. Seventeen index IDs have no code or test
reference, which is a traceability gap rather than an error.

### DOC-2. Dead code
Confirmed by search across the app and both test targets.
- Views: `NowPlayingView.swift` (referenced only by its own preview),
  `StatCardView.swift`, `PlaybackCollectionContextView`,
  `SettingsLabeledStepper`, `DashboardBadge` and `badgeTint(for:role:)`.
- `NowPlayingPaneView.showsArtworkThemeDebugButton` is hard-coded `false`,
  which makes the button, its sheet, four state properties and all 684 lines
  of `AlbumArtworkThemeDebugView.swift` unreachable in every build.
- Sync: `PlaylistSyncService.syncPlaylist(id:source:in:)`,
  `syncAllLinkedPlaylists`, `playableMusicTracks(for:)`;
  `PlaylistRemoteMutationCoordinator.rewrite` and
  `PlaylistRemoteMutationPolicy.shouldDeleteRemotelyAfterEviction` (tests
  only); `AppleMusicPlaylistTrackLoader.songSnapshots(from:)` (tests only).
- `CachingMusicLibraryPlaylistFetcher`'s full-list cache is never populated
  in production, because both real fetchers override the default that would
  fill it.
- `AlbumArtworkThemeDiagnostics.log` discards its message, but every call
  site still builds the string.

### DOC-3. Large files
| File | Lines | Note |
|---|---|---|
| `Services/PlaybackController.swift` | 2,934 | see section 3 |
| `Presentation/AlbumArtworkTheme.swift` | 2,124 | colour heuristics; not reviewed for colour correctness |
| `CarPlaySupport/CarPlayCoordinator.swift` | 1,433 | six parallel template/renderer/ID sets and two near-identical stack rebuilders; CO-7, CR-5 and CO-9 are bookkeeping slips between them |
| `App/Shell/SplitAppShell.swift` | 876 | layout policy, sidebar panel, fade state machine, menu commands and three UIKit helpers |
| `Views/NowPlaying/NowPlayingComponents.swift` | 865 | eight views, a palette and three button styles |
| `Views/SettingsView.swift` | 782 | iOS form and Mac pane in one file |

A small per-list type in the CarPlay coordinator (template, renderer, refresh
closure) would remove most of its repeated bookkeeping.

## What was found sound

- **Destructive sync steps fail closed.** Entry paging rejects missing, empty,
  repeated or overlapping pages, and absence-based steps are gated on a
  complete read. An empty or partial fetch cannot be read as "the playlist is
  now empty".
- **Remote rewrites.** `removeSongsHeldOutside` writes only when the device's
  entries equal iCloud's by occurrence count, remembers an edit refusal and
  never edits on a Mac. The mutation coordinator's gate hand-off is correct.
- **CloudKit model constraints.** Every stored attribute is optional or
  defaulted and none is unique.
- **Rebuild.** `LibraryRebuildService` stages in a private context and commits
  graph and receipt in one save.
- **Listen ledger.** Session-ID idempotency and baseline handling match
  `COUNT-002`.
- **Artwork.** Colour extraction and text recognition run off the main actor
  on downsampled images; download coalescing has no suspension between check
  and insert.
- **Build settings.** Swift 6 on all nine target configurations; deployment
  target 26.4 everywhere; Debug and Release differ as they should; no team ID
  or real bundle ID in the tracked project; file-system-synchronized groups
  mean no file can be on disk but missing from a target.
- **Conditional compilation.** No release-critical code is compiled only under
  `DEBUG`, apart from the diagnostics UI in REL-1. The `#error` guards on the
  development flags are sound.

## Not reviewed

- Nothing was compiled, run, profiled or tried on a device or in a car.
- Colour-selection heuristics in `AlbumArtworkTheme.swift` and the thresholds
  in `MusicKitActivityReport.swift` were read for threading and crash risk
  only.
- Most non-playback test files were checked by name and search, not read for
  assertion quality.
- `Diagnostics/` Python scripts, beyond a scan for secrets and shell calls.
- The spec body, beyond the sections each slice needed.
- Mac Catalyst ID domains at runtime (see DI-3).
