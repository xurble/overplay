# Overplay Roadmap

This is the single living planning document for Overplay. Read it alongside
`OVERPLAY_DESIGN_SPEC.md`, which specifies current behaviour and product
invariants.

The order below is the current impact order for reaching a dependable
iPhone-and-CarPlay beta. Correctness and confidence in the existing product come
before platform expansion and secondary polish. Reorder it when product goals
change or new evidence changes the risk.

## 1. Continuously Re-verify Cross-Surface Playback

The initial physical-device acceptance pass was completed on 2026-09-08. This
is a standing release gate rather than a finished one-off task: repeat the
affected parts after every change to playback, queue correlation, MusicKit
modes, CarPlay templates, remote commands, suspended-playback reconciliation,
or Now Playing publication.

For every supported action origin — SwiftUI, CarPlay, and the system
remote-command path (Lock Screen, Control Center, headset, or media key) — and
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

Track [GitHub issue #9](https://github.com/xurble/overplay/issues/9). It spans
several independently verifiable changes and should be delivered in focused
slices:

1. Persist the background-entry waypoint before awaiting supporting MusicKit
   metadata so suspension cannot lose the baseline.
2. Ensure every background refresh outcome leaves the next useful request
   armed, including task expiration and temporarily unobservable playback.
3. Prevent one play from producing both a stale-observation event and a
   reconciled playthrough event.
4. Add service-level regression coverage for the durable ledger, retained
   baselines, expiry and cap, regression guard, deduplication, and save rollback.
5. Decide the bounded upcoming-track baseline window and whether a MusicKit
   `playCount` delta greater than one can credit multiple plays before adding
   pre-seeding.
6. Remove the unused `remote-notification` background mode, retain `fetch`, and
   remove `audio` or document why it is required after device verification.

Skips must remain witnessed-only. Any change that can double-count, attribute a
play to the wrong playlist item, or weaken the conservative proof policy is a
release blocker.

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

## 5. Isolate Playback Tests from Process-Global Defaults

Track [GitHub issue #18](https://github.com/xurble/overplay/issues/18).

Inject the local playback-state `UserDefaults` domain through
`PlaybackController`, preserve `.standard` in production, and give every test
fixture a unique disposable suite. Keep parallel execution enabled and run the
configured full suite repeatedly to demonstrate that the reported intermittent
failure is gone.

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

## 10. Publish Now Playing Artwork

Publish artwork through `MPNowPlayingInfoCenter` in addition to title, artist,
album, duration, elapsed time, and playback rate. Reuse the existing artwork
cache and avoid blocking playback-state publication on image loading.

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

## 13. Add the Native Mac Target

- Add a native SwiftUI macOS target sharing models, repositories, services, and
  reusable views.
- Start with dashboard, playlist management, history, settings, and read-only
  data sync if playback needs a later slice.
- Isolate platform-specific media APIs behind adapters.

Verification:

- The macOS target builds.
- Shared unit tests still pass.
- No iOS-only APIs leak into shared code.

## 14. Add Mac Interaction Polish

- Add menu commands, keyboard shortcuts, and context menus.
- Use table-style history and playlist lists where useful.
- Add media-key and Now Playing support where available.
- Support a compact mini-player window if practical.

## 15. Consider CarPlay Skip-History Browsing

Add skip-history browsing only if it fits safely within CarPlay templates and
does not make the primary playlists → tracks → Now Playing flow harder to use.
CarPlay browsing remains focused on Active playlists; Retired content appears
only when it is the current playback context started elsewhere.

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

### Siri and System Surfaces

- Add App Intents backed by the existing shared services for playing the One
  True Playlist or triage bucket and for promoting, retiring, or restoring the
  current track. Adopt the system audio schemas where they accurately represent
  the action so Siri, Shortcuts, Spotlight, the Action button, and Apple
  Intelligence receive consistent semantics.
- Support Music Haptics by persisting ISRC, publishing
  `MPNowPlayingInfoPropertyInternationalStandardRecordingCode`, and declaring
  `MusicHapticsSupported`. Keep this aligned with issue #40's identity work.
- Consider `changePlaybackPositionCommand` for Lock Screen and Control Center
  scrubbing only after defining seek-aware session accounting; jumping forward
  must not manufacture a playthrough or hide a witnessed skip.
- Experiment with `likeCommand`, `dislikeCommand`, or `bookmarkCommand` as
  standard Promote, Retire, or Save-for-later controls. Verify their actual
  presentation on iPhone and CarPlay before relying on them.
- Extend Now Playing publication, after the scheduled artwork work, with useful
  queue index/count and stable external, collection, or service identifiers
  where those values improve system behavior.

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
