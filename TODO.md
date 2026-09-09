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

Issue #34 replaces the separate triage playlists with one shared bucket fed by
contributing Apple Music playlists. Issue #36 then makes track membership
globally exclusive: one row per track app-wide, with skip and playthrough
counts travelling with the track as it moves, and retired tracks living in the
bucket. #36 depends on #34.

Both reshape persistence, so they must land before the data-preservation
decision below, while a schema reset is still cheap. The device holding the
only existing dataset means migration is best effort on stats and strict on
consistency — merge counts where it is straightforward, and never introduce a
versioned schema for it.

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
