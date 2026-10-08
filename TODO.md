# Overplay Roadmap

This is the single living planning document for Overplay. Read it alongside
`OVERPLAY_DESIGN_SPEC.md`, which specifies current behaviour and product
invariants.

The order below is the current impact order for reaching a dependable
iPhone-and-CarPlay beta, following the **Product priorities** in the spec
(reliable player, then CarPlay and Siri, then playlist management, then
statistics). Correctness and confidence in the existing product come
before platform expansion and secondary polish. Reorder it when product goals
change or new evidence changes the risk.

## 1. Device-Verify the Playback Core Rewrite, Then Keep Re-verifying

[GitHub issue #61](https://github.com/xurble/overplay/issues/61) rebuilt the
playback core: a persisted playback intent, player-authoritative display,
single-call transport, user-initiated recovery, system-owned Now Playing and
the listen ledger. It has unit evidence only. Run the acceptance pass on My Mac
(Designed for iPad) for live MusicKit, and on iPhone with CarPlay hardware.
After that it remains a standing release gate: repeat the affected parts after
every change to playback, attribution, MusicKit modes, CarPlay templates,
suspended-playback reconciliation or counting.

Rewrite-specific checks:

- CarPlay Now Playing follows the playing track on the installed iOS version
  with the diagnostic mirror off. If it does not (a reported iOS 27 issue),
  compare with **Settings → Mirror Now Playing from Overplay** on, and record
  the result in the spec before changing the default.
- CarPlay shuffle and repeat buttons show MusicKit's real modes (#28).
- A track Overplay cannot attribute still shows on every surface, and Promote
  and Retire are disabled for it.
- Force a failure (airplane mode mid-track): every surface shows it, Pause
  still works, and Play recovers without restarting the phone.
- Relaunch while music is still playing: Overplay re-attaches without
  restarting the queue.
- Cold launch before iCloud restoration: CarPlay offers Resume and plays.
- Play Album and Play Artist (`PLAY-018`, #83) from the app and from the
  CarPlay album/artist button: the album starts at track 1; an artist plays
  Essentials, or Top Songs without repeated versions, in more than one
  storefront language; untracked songs offer Add to Triage and Add to One
  True Playlist and are not counted; tracked songs count; Play after a
  relaunch resumes the album. Check whether Add to One True Playlist works on
  My Mac (Designed for iPad).

For every supported action origin — SwiftUI, CarPlay, and the system
transport controls (Lock Screen, Control Center, headset, or media key) — and
for natural MusicKit track advancement, verify that current-track identity,
queue context, play state, position, outgoing-track statistics/history,
active-playlist projection, restore state, CarPlay presentation, and system
Now Playing metadata converge without navigation, relaunch, template reset,
periodic playlist sync, or manual refresh. Any stale surface is a
release-blocking regression even when audio remains correct.

Relevant regression checks:

- Skip at less than 10 seconds: no skip counted.
- Skip at about 30%: skip counted once.
- Skip at about 70%: neither skip nor playthrough.
- Natural completion: playthrough counted once.
- Lock the phone, let several tracks play, then unlock: no phantom skips or
  missing-track misattribution.
- Pause mid-track, force-quit, relaunch, then play another playlist: no phantom
  event for the restored track.
- Manual-add a searched track, then sync: one row, counts intact.
- Promote a bucket track, then sync the contributing playlist and the One True
  Playlist: one One True Playlist row.
- Rapid Next presses: app UI, Lock Screen, and CarPlay agree; no bogus history
  events.
- At the final track, repeat off stops after crediting the playthrough; repeat
  all wraps under MusicKit control; shuffle state remains unchanged.
- Retire the current track: playback advances and remote removal is attempted
  according to policy.
- Two devices on one account: playback remains independent and shared counts
  converge without duplicate rows.

## 2. Harden Suspended-Playback Reconciliation

The lifecycle and service changes for [GitHub issue #9](https://github.com/xurble/overplay/issues/9)
now persist waypoints before metadata awaits, re-arm refreshes before work, keep
stale observations out of outcome history, and pre-seed up to 20 following
tracks. Recovery retains at most 41 baselines for 24 hours and credits at most
one playthrough per qualifying counter advance. Service regression coverage
includes cancellation, persistence rollback, deduplication, and relaunch.

Remaining physical-device checks:

- Validate delayed MusicKit counter propagation after a long suspended span,
  including shuffle and unavailable metadata.
- Confirm whether the existing `audio` background mode is necessary for
  MusicKit/CarPlay before removing it. `remote-notification` is removed and
  `fetch` is retained.

Skips remain witnessed-only; ambiguous or unsampled playback can under-count.

## 3. Restore CarPlay Curation Controls

Track [GitHub issue #22](https://github.com/xurble/overplay/issues/22).

The shared action policy already specifies Shuffle and Repeat followed by the
appropriate Promote, Retire, or Restore actions. The outstanding problem is the
reported absence of custom action controls in the rendered CarPlay Now Playing
surface. Verify image sizing and rendering on physical CarPlay hardware and keep
all mutations routed through the shared playback controller.

## 4. Stabilize the CarPlay Shuffle Indicator

Track [GitHub issue #28](https://github.com/xurble/overplay/issues/28).

First use the existing Apple Music activity diagnostics to determine whether
only the button presentation flickers or MusicKit's actual shuffle mode changes
after a track transition. Preserve real player state changes; do not hide a
functional mode transition with presentation debouncing.

## 5. Close Out Playback Test Isolation

[GitHub issue #18](https://github.com/xurble/overplay/issues/18) is superseded
by #61. The controller now takes an injected intent store and player, and every
fixture uses its own disposable store. Run the full suite repeatedly in
parallel to confirm the intermittent failure is gone, then close #18.

## 6. Resolve CarPlay Now Playing Navigation Semantics

Track [GitHub issue #27](https://github.com/xurble/overplay/issues/27).

Current intent is that Back returns one level and Up Next returns to Overplay's
root playlist menu. Reproduce the reported identical behaviour on hardware. If
the two controls are effectively redundant, remove Up Next; otherwise make and
verify the distinction without adding another navigation level.

## 7. Finish the Triage Bucket Restructure

Track [GitHub issue #34](https://github.com/xurble/overplay/issues/34) and
[GitHub issue #36](https://github.com/xurble/overplay/issues/36).

Issue #34 is complete: one shared bucket is fed by contributing Apple Music
playlists. Issue #36 makes track membership
globally exclusive: one row per track app-wide, with skip and playthrough
counts travelling with the track as it moves, and retired tracks living in the
bucket and appearing in a third top-level Retired collection. It also includes
source-link revival (not ordinary sync), stale OTP suppression, independent
manual/restore keep intent, and last-source/retirement/reset cleanup. Active
reset history survives unlink; retired unowned current 0/0 rows do not.

Both reshape persistence, so they must land before the data-preservation
decision below, while a schema reset is still cheap. The device holding the
only existing dataset means migration is best effort on stats and strict on
consistency — merge counts where it is straightforward, and never introduce a
versioned schema for it. After identity/count convergence, the one historical
cleanup deletes legacy unowned 0/0 rows even with reset history. Explicit keep,
active OTP and necessary stale-OTP protection survive. New rows are marked to
exclude them from the historical exception on repeated startup/CloudKit import.

Per section 1, treat these as cross-surface playback changes: the bucket is a
playback context with a reserved identifier rather than an Apple Music
playlist, so CarPlay browsing, Now Playing actions, restore state and the
active-playlist projection all need re-verification.

## 8. Complete Beta Settings and Data Hardening

- Add an explicit reset-local-playback-state control.
- Clarify the distinction between resetting statistics, resetting device-local
  playback state, and deleting shared local/iCloud data.
- Add a direct action to open system Settings when Apple Music permission is
  denied.
- Before public beta, decide whether existing tester CloudKit data must be
  preserved.
  - If preservation is required, add an explicit SwiftData migration from
    pre-release stores that included `TrackedTrack`, `PlaybackEvent`, or
    `SettingsRecord`.
  - Otherwise, document that beta testers must delete local app data and
    CloudKit development data before installing the release build.

The app remains pre-release, so development schema resets are acceptable until
that decision is made.

## 9. Refine the iPad Experience

- Improve playlist management, playlist detail, history, and Now Playing in
  split layouts.
- Add toolbar actions for existing workflows.
- Add useful hardware keyboard shortcuts without breaking touch workflows.
- Verify Stage Manager, Split View, and scene-local navigation in multiple
  windows.

Verification:

- Regular-width layouts do not look like stretched phone UI.
- Window navigation and playback state remain correctly separated.
- Keyboard shortcuts do not break touch workflows.
- The app target and relevant tests pass.

## 10. (Withdrawn) Publish Now Playing Artwork

Withdrawn by #61: the `ApplicationMusicPlayer` host publishes system Now
Playing, including artwork (`PLAY-016`). Overplay writes nothing there unless
the diagnostic mirror is on.

## 11. Expand the Dashboard Summary

- Add recently promoted counts.
- Surface useful triage queues such as unreviewed or high-skip items.
- Add direct play, sync, search, and history actions where they shorten an
  existing workflow.

## 12. Move Sync Persistence off the Main Actor Only if Profiling Requires It

Playlist sync currently runs on the MainActor against the main `ModelContext`,
with yield chunking, once-per-cycle identity merge, a shared library-playlist
fetch, and inter-playlist pacing.

If on-device catch-up sync still hitches:

- Move persistence work to a `@ModelActor`-based background context.
- Add ID-based re-fetch APIs at live `@Model` boundaries.
- Keep MusicKit fetches behind sendable snapshot boundaries.
- Preserve immediate shared playback-state updates after persistence writes
  that affect current playback UI.

Do not undertake this refactor without profiling evidence.

## 13. Build the Mac Helper

Build the menu bar helper in **Mac Helper — Planned** (`HELPER-001`–`HELPER-011`)
before the native Mac target, which stays the long-term goal.

1. Close the spec's open checks with throwaway scripts: song IDs in
   `Library.musicdb`, script adds of playlist-only songs, and iCloud
   propagation of script edits.
2. Read-only first: the target, the CloudKit zone, `HelperStatus`, library
   facts, playlist snapshots, backups and stamp history, and the Settings →
   Mac Helper screen.
3. Fast Triage intake.
4. The One True Playlist writer, starting in plan-only mode.
5. Source cleanup (default off), after the writer has run cleanly for a while.

Verification:

- Unit tests cover desired-state merging, the reconcile plan (removals only
  for suppressed songs, no guessing, collapse, approval thresholds) and the
  iPhone/iPad changes while the writer is on.
- Source cleanup tests cover: restores only from the helper's own removal
  log, skipped sources that cannot be edited, no fighting a source that
  re-adds a song, and putting songs back when the option is turned off or a
  source is unlinked.
- On the owner's Mac and iPhone: a retirement on iPhone leaves Apple Music's
  playlist after the Mac wakes; a promotion appears; a stale device cannot add
  a retired song back; nothing changes in playback. With source cleanup on, a
  retired TikTok song leaves TikTok Songs, and moving it to Triage puts it back.

## 14. Add the Native Mac Target

- Add a native SwiftUI macOS target sharing models, repositories, services, and
  reusable views.
- Start with dashboard, playlist management, history, settings, and read-only
  data sync if playback needs a later slice.
- Isolate platform-specific media APIs behind adapters.

Verification:

- The macOS target builds.
- Shared unit tests still pass.
- No iOS-only APIs leak into shared code.

## 15. Add Mac Interaction Polish

- Add menu commands, keyboard shortcuts, and context menus.
- Use table-style history and playlist lists where useful.
- Add media-key and Now Playing support where available.
- Support a compact mini-player window if practical.

## 16. Consider CarPlay Skip-History Browsing

Add skip-history browsing only if it fits safely within CarPlay templates and
does not make the primary playlists → tracks → Now Playing flow harder to use.
CarPlay browsing remains focused on Active playlists; Retired content appears
only when it is the current playback context started elsewhere.

## Siri Playlist Management (Committed, Not Yet Scheduled)

Product priority 2 (CarPlay and Siri first). This work is deferred until the
playback core is device-verified; it is not a candidate or a non-goal.

- Add App Intents backed by the existing shared services for playing the One
  True Playlist or triage bucket and for promoting, retiring, or restoring the
  current track. Adopt the system audio schemas where they accurately represent
  the action so Siri, Shortcuts, Spotlight, the Action button, and Apple
  Intelligence receive consistent semantics.

## Unscheduled Music Platform Enhancements

The highest-value MusicKit infrastructure opportunities are tracked separately:

- [GitHub issue #39](https://github.com/xurble/overplay/issues/39) — adopt
  `Playlist.Entry` for playlist sync and reconciliation.
- [GitHub issue #40](https://github.com/xurble/overplay/issues/40) — resolve
  library, catalog, and storefront identities through documented equivalence
  APIs.
- [GitHub issue #41](https://github.com/xurble/overplay/issues/41) — observe
  MusicKit queue and player state for prompt shared reconciliation.

The ideas below are candidates, not committed roadmap priorities. Promote one to
a scoped issue only when its product benefit justifies its interaction with the
shared playback, persistence, and cross-surface invariants above.

### Discovery and Intake

The shared manual Triage intake boundary already tracks explicit keep intent
independently of contributing playlists. Future intake UI must use it; do not
invent a fake playlist or bypass the global ownership/retention rules.

- Read the user's synced Shazam discoveries from `SHLibrary` and feed them
  directly into the triage bucket, retaining Apple Music ID, ISRC, artwork, and
  discovery date where available. Consider in-app Shazam recognition only if it
  adds value beyond the system Music Recognition control.
- Build a discovery inbox from MusicKit personal recommendations, recently
  played content, or Apple Music Replay summaries. Treat these as suggestions
  only: recently played results do not prove completion or identify the source
  playlist and must never directly change Overplay statistics.
- Explore song stations, artist relationships, catalog charts, genres, and
  record-label relationships as optional ways to find candidates related to a
  track the user kept or promoted.
- Consider syncing Apple Music favorites or positive/negative ratings only as
  an explicit opt-in. Promotion and retirement are Overplay concepts and should
  not silently change the user's Apple Music taste profile.

### Search and Library Browsing

- Combine `MusicLibrarySearchRequest` with the current catalog search so
  purchases, imports, uploads, and library-only tracks can be found without
  losing catalog results.
- Add `MusicCatalogSearchSuggestionsRequest` for autocomplete and top results.
- Offer an offline-focused view or playback filter based on MusicKit's
  `includeOnlyDownloadedContent` support if device testing shows that it maps
  cleanly to Overplay's linked playlists.
- Consider MusicKit's system music picker after it leaves beta and demonstrates
  a clear advantage over Overplay's purpose-built selection flows.

### System Surfaces

System Now Playing and remote commands belong to `ApplicationMusicPlayer`'s
host (`PLAY-016`). Ideas that need Overplay to publish Now Playing metadata or
register remote commands (ISRC publication for Music Haptics, like/dislike
commands as Promote/Retire, extra Now Playing identifiers) are withdrawn with
History H-7. Promote, Retire and Restore away from the phone come from CarPlay
templates (§3) and Siri (Siri Playlist Management).

- Support Music Haptics only if it works without Overplay-authored Now
  Playing, for example if the player host already publishes the ISRC.
- Lock Screen and Control Center scrubbing are the player host's. Define
  seek-aware session accounting so a scrub never manufactures a playthrough or
  hides a witnessed skip (see the same-entry replay item in the spec's Known
  Defects).

### Playback Experience

- Offer MusicKit crossfade as an opt-in playback setting after testing its
  effect on current-entry transitions, elapsed-time accounting, queue-end
  behavior, and cross-surface state.
- Consider a rapid audition mode using queue-entry `startTime` and `endTime`
  windows for triage. It needs distinct statistics semantics because a planned
  short window is neither a normal skip nor a full playthrough.
- If the minimum OS rises to iOS 26.4 or later, consider setting
  `queue.affectsListeningHistory` to false for clearly labeled audition or
  retired-review sessions. Do not disable it for normal playback without
  replacing the Apple Music play-count evidence used by suspended-playback
  reconciliation.
- Surface the active `MusicPlayer.State.audioVariant` or catalog audio variants
  as restrained Lossless, Hi-Res Lossless, or Dolby Atmos badges, following
  Apple's badge guidance and showing the actual active format where possible.

### Reactive Library and Subscription State

- Use `MPMediaLibraryDidChangeNotification` as a debounced invalidation hint for
  MusicKit playlist caches and linked-playlist sync. Retain periodic sync because
  the notification does not describe the changed resources or guarantee remote
  delivery timing.
- Observe `MusicSubscription.subscriptionUpdates` so subscription and Sync
  Library changes update readiness without requiring a relaunch or manual
  refresh.
- If non-subscribers become part of the intended audience, present MusicKit's
  native subscription offer rather than only reporting that catalog playback is
  unavailable.
