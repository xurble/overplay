# Overplay

Overplay is an Apple Music companion app that helps keep a main playlist
fresh. It tracks how often you play through or skip each track, presents that
per-playlist play/skip history, and makes it easy to retire tracks that keep
getting skipped. It currently runs on iPhone (with CarPlay support); iPad
layouts exist via the adaptive shell, and a native Mac target is planned.

The app is built around a **One True Playlist** plus optional **triage
playlists**. The One True Playlist is the main playlist Overplay manages.
Triage playlists are intake sources, such as Shazam saves, TikTok discoveries,
a friend's playlist, or any other playlist you want to review before promoting
songs into the main playlist.

## How It Works

Overplay syncs linked Apple Music playlists into its own SwiftData store. It
tracks skip counts, playthrough counts, playlist membership, promotions, and
retirement history separately from Apple Music's global play count or skip
count. Skips and playthroughs are counted per playlist item, from witnessed
listening time — a transition only counts as a skip if the app actually
observed enough of the session, so playback that happens while Overplay is
suspended never produces phantom skips. Playthroughs completed while
suspended are recovered on the next wake (a scheduled background refresh or
simply reopening the app) whenever they can be proven — either a snapshot
catching the track past the playthrough threshold, or wall-clock accounting
showing the span played continuously. Anything ambiguous counts nothing.

Retirement is the user-facing state for tracks removed from Active playback:
Overplay surfaces playthroughs versus skips for every linked
playlist, and tracks are retired by explicit user action. Promotion moves a
track from a triage playlist into the One True Playlist.

Playlist detail on iOS is split into **Active** and **Retired** views. Active
contains the playable playlist; Retired contains locally retired tracks and can
be played as its own playlist context in the app. Restoring a retired track
makes it active again. Both Active and Retired lists follow device-local
persisted playback order, seeded by the last randomization, rather than raw
database order.

When a track is retired, Overplay always records the event locally. If Apple
Music allows the app to remove the track from the linked playlist, Overplay
tries to do that too. If remote deletion is unavailable or fails, Overplay
keeps the local retirement and filters the track out of Active playback.

## Playback

Playback uses MusicKit's application music player with a shared playback
controller behind every surface: the in-app Now Playing UI and mini player,
CarPlay, Lock Screen, Control Center, and headset/remote commands. All
surfaces route through the same controller, queue policies, and
skip/playthrough evaluation, so a skip from CarPlay or the Lock Screen counts
the same as a skip in the app.

## Sync and Data

Shared app data is backed by iCloud/CloudKit so devices on the same account
can share playlist definitions, track stats, promotions, and retirement
history. Linked playlists are periodically re-synced from Apple Music, with
additions and updated track metadata reconciled into the local store. Tracks
that disappear from the remote playlist are left in place locally with their
history preserved; local retirement remains the only way to exclude a track
from Active playback.

Playback state stays local to each device. The currently playing track,
queue, position, selected view, shuffle/repeat state, and window-specific
navigation state do not sync across devices. This lets an iPhone, iPad, and
Mac share Overplay data without controlling each other's playback.

## Project Shape

- Swift 6, SwiftUI
- iOS 26 and iPadOS 26 or later (native macOS target planned)
- MusicKit-first Apple Music integration
- SwiftData with CloudKit-backed shared state
- CarPlay music player scene
- Adaptive shell: compact navigation on iPhone, split view/sidebar on iPad
- Liquid Glass UI direction
- Swift Testing unit test target (`OverplayTests`) covering repositories,
  playback policies, sync reconciliation, and presentation logic

## Documentation

- [OVERPLAY_DESIGN_SPEC.md](OVERPLAY_DESIGN_SPEC.md) — full product and
  technical direction.
- [TODO.md](TODO.md) — the single living roadmap for remaining platform,
  product, verification, performance, and release-hardening work.
- [AGENTS.md](AGENTS.md) — rules for AI agents working in this repo,
  including the shared playback-surface requirements.
- [Overplay/CarPlaySupport/README-CarPlay.md](Overplay/CarPlaySupport/README-CarPlay.md)
  — current CarPlay surface structure and verification notes.

## Local Configuration

Shared build settings live in `Overplay/Config/Shared.xcconfig`. Local
developer identifiers should live in `Overplay/Config/Local.xcconfig`, which
is ignored by git.

To configure a local checkout:

1. Copy `Overplay/Config/Local.example.xcconfig` to `Overplay/Config/Local.xcconfig`.
2. Set `DEVELOPMENT_TEAM`.
3. Set `PRODUCT_BUNDLE_IDENTIFIER`.
4. Set `ICLOUD_CONTAINER_IDENTIFIER`.

Apple Music and CloudKit capabilities must be configured in the Apple
Developer portal and in the Xcode target for the identifiers you use.

## Current Status

The core product loop is in place: linked playlist management, periodic sync
with reconciliation, playback with per-playlist shuffle order, skip and
playthrough tracking, manual retirement and promotion, unified history, search
and manual add, CarPlay, and the adaptive iPhone/iPad shell. Remaining
roadmap work is iPad experience refinement and the native Mac target
alongside the open product, verification, performance, and release-hardening
items tracked in `TODO.md`. The app is pre-release: the schema may still reset
between builds (see the pre-release data policy in `AGENTS.md` and the release
hardening section in `TODO.md`).
