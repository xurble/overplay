# Overplay

Overplay is an Apple Music companion app for iPhone, iPad, and Mac. It helps
keep a main playlist fresh by tracking how often you play through or skip
tracks, then evicting songs that keep getting skipped.

The app is built around a **One True Playlist** plus optional **triage
playlists**. The One True Playlist is the main playlist Overplay manages.
Triage playlists are intake sources, such as Shazam saves, TikTok discoveries,
a friend's playlist, or any other playlist you want to review before promoting
songs into the main playlist.

## How It Works

Overplay syncs linked Apple Music playlists into its own SwiftData store. It
tracks skip counts, playthrough counts, playlist membership, promotions, and
eviction history separately from Apple Music's global play count or skip count.

Count-based eviction applies only to the One True Playlist. Triage playlists
still track skips and playthroughs, but songs are promoted or removed manually.

When a track is evicted, Overplay always records the event locally. If Apple
Music allows the app to remove the track from the linked playlist, Overplay
should try to do that too. If remote deletion is unavailable or fails, Overplay
keeps the local eviction and filters the track out of future playback.

## Sync and Data

Shared app data is backed by iCloud/CloudKit so devices on the same account can
share playlist definitions, track stats, promotions, and eviction history.

Playback state stays local to each device. The currently playing track, queue,
position, selected view, shuffle/repeat state, and window-specific navigation
state should not sync across devices. This lets an iPhone, iPad, and Mac share
Overplay data without controlling each other's playback.

## Project Shape

- Swift 6
- SwiftUI
- iOS 26, iPadOS 26, and macOS 26 or later
- MusicKit-first Apple Music integration
- SwiftData with CloudKit-backed shared state
- Liquid Glass UI direction across Apple platforms

The full product and technical direction lives in
[OVERPLAY_DESIGN_SPEC.md](OVERPLAY_DESIGN_SPEC.md).

## Local Configuration

Shared build settings live in `Config/Shared.xcconfig`. Local developer
identifiers should live in `Config/Local.xcconfig`, which is ignored by git.

To configure a local checkout:

1. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`.
2. Set `DEVELOPMENT_TEAM`.
3. Set `PRODUCT_BUNDLE_IDENTIFIER`.
4. Set `ICLOUD_CONTAINER_IDENTIFIER`.

Apple Music and CloudKit capabilities must be configured in the Apple
Developer portal and in the Xcode target for the identifiers you use.

## Current Status

This codebase is evolving from the initial implementation toward the long-term
design in the spec. Expect some existing models and screens to lag behind the
new multi-playlist, iCloud-backed, multi-platform design while the app is
reworked incrementally.
