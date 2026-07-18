# Overplay Roadmap

This is the single living planning document for Overplay. Completed historical
plans have been removed from the repository so this file only tracks open work,
deferred follow-ups, and release-hardening reminders.

Read this alongside `OVERPLAY_DESIGN_SPEC.md` for the long-term product and
technical direction.

## Platform Experience

### Refine iPad Experience

- Improve playlist management, playlist detail, history, and Now Playing in
  split layouts.
- Add iPad toolbar actions where workflows already exist.
- Add useful hardware keyboard shortcuts without breaking touch workflows.
- Support Stage Manager and multiwindow-friendly state.

Verification:

- iPad simulator layout is not stretched phone UI.
- Keyboard shortcuts do not break touch workflows.
- App target builds and relevant tests pass.

### Add Native Mac Target

- Add a native SwiftUI macOS target sharing models, repositories, services, and
  reusable views.
- Start with dashboard, playlist management, history, settings, and read-only
  data sync if playback needs a later slice.
- Isolate platform-specific media APIs behind adapters.

Verification:

- macOS target builds.
- Shared unit tests still pass.
- No iOS-only APIs leak into shared code.

### Add Mac Interaction Polish

- Add menu commands, keyboard shortcuts, and context menus.
- Use table-style history and playlist lists where useful.
- Add media-key and Now Playing support where available.
- Support a compact mini-player window if practical.

Verification:

- Mac workflows feel native.
- Media commands are local to the Mac.
- macOS target builds.

## Product Gaps To Reconcile With The Spec

### Dashboard Summary

- Expand the dashboard beyond playlist launchers.
- Add recently promoted counts, triage queues with unreviewed or high-skip
  items, and direct play, sync, search, and history actions.

### Settings

- Add an explicit reset-local-playback-state control.
- Revisit whether reset stats, shared data reset, and local playback reset need
  clearer separation before beta.
- Add a direct action to open system Settings when Apple Music permission is
  denied.

### CarPlay

- Add skip-history browsing if the interaction fits safely within CarPlay templates.
- Keep browsing focused on Active playlists; Retired content should only appear
  when it is the current playback context started elsewhere.
- Continue routing all controls through shared playback and track action
  services.

### Now Playing Metadata

- Publish artwork through `MPNowPlayingInfoCenter` in addition to title, artist,
  album, duration, elapsed time, and playback rate.

### Behavior Decisions

The implementation currently differs from the design spec in these areas.
Resolve each by either updating the spec to match the product decision or
changing the implementation.

- Promotion locally retires the source triage item after a successful
  promotion; the spec says leave the source unchanged unless a future setting
  says otherwise.
- Remote deletion is attempted only for managed Apple Music One True Playlist
  items; the spec says manual retirement should attempt removal when supported.
- Playlist-row retirement is local-only and does not use the current-track remote
  deletion path.
- Search only offers active playlists that allow remote writes; the spec says
  users can add tracks to any linked playlist.
- History is a filtered list everywhere; Mac should revisit sortable and
  filterable table presentation.

## Performance And Responsiveness Follow-Ups

### Background Sync Context

Playlist sync currently runs on the MainActor against the main `ModelContext`,
with yield chunking, once-per-cycle identity merge, a shared library-playlist
fetch, and inter-playlist pacing.

If on-device catch-up sync still hitches:

- Move sync persistence work to a `@ModelActor`-based background context.
- Add ID-based re-fetch APIs at live `@Model` boundaries.
- Keep MusicKit fetches behind sendable snapshot boundaries.
- Preserve immediate shared playback-state updates after persistence writes that
  affect current playback UI.

## Playback And Device Verification

The automated playback and identity-fix test suite passed on the iPhone
simulator after the remediation work. The remaining checklist requires a
physical device with an Apple Music subscription.

- Skip at less than 10 seconds: no skip counted.
- Skip at about 30%: skip counted once.
- Skip at about 70%: neither skip nor playthrough.
- Natural completion: playthrough counted once.
- Lock the phone, let several tracks play, unlock: no phantom skips and no
  missing-track misattribution.
- Pause mid-track, force-quit, relaunch, play another playlist: no phantom event
  for the restored track.
- Manual-add a searched track, then sync: single row, counts intact.
- Promote a triage track, then sync both playlists: single One True Playlist
  row.
- Rapid Next presses: app UI, Lock Screen, and CarPlay agree; no bogus history
  events.
- Last track finishes naturally: reshuffled repeat starts; recently played
  track is not in the new top five.
- Retire the current track: playback advances and remote removal is attempted per
  policy.
- Two devices on one account: playback remains independent and counts converge
  without duplicate rows.

## Release Hardening

Overplay is still pre-release, so local development schema resets are
acceptable. Before the first public beta or release:

- Review whether existing testers have CloudKit data that must be preserved.
- If preservation is required, add an explicit SwiftData migration from any
  pre-release stores that included `TrackedTrack`, `PlaybackEvent`, or
  `SettingsRecord`.
- If preservation is not required, document that beta testers should delete
  their local app data and CloudKit development data before installing the
  release build.
