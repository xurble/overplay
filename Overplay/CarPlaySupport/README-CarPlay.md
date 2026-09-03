# CarPlay Support

CarPlay is an active Overplay surface. The app target has the CarPlay audio
entitlement, and `Config/Info.plist` declares a CarPlay scene using
`CPTemplateApplicationScene`.

## Structure

- `CarPlaySceneDelegate` receives CarPlay scene connections and hands the
  `CPInterfaceController` to `CarPlayCoordinator`.
- `CarPlayCoordinator` owns CarPlay templates and keeps CarPlay-specific types
  isolated from the SwiftUI iPhone/iPad shell.
- `CarPlayLibrarySnapshot` builds testable playlist summaries for the CarPlay
  list UI.
- `CarPlayNavigationPolicy` decides what the root `Overplay` row and the track
  rows do, free of CarPlay types so the rules are testable.
- `AppRuntime.shared` provides the shared model container, playback controller,
  authorization service, and remote command service used by both phone UI and
  CarPlay.

## Current CarPlay UI

The root template has no navigation-bar actions. It shows:

- An `Overplay` row. When the One True Playlist is already the live queue it
  opens Now Playing, resuming first if playback is paused; otherwise it
  reshuffles the One True Playlist, starts it from the new first track, and
  opens Now Playing. It is disabled when no One True Playlist is chosen or it
  has no playable tracks.
- A row for the One True Playlist itself, which opens its track list.
- A separate section of the active triage playlists, which open the same
  track-list screen.

A track list starts with a `Shuffle` row, then the tracks in their current
local order. Shuffle reshuffles the scope being shown, starts from the new
first track, and opens Now Playing.

Tapping a track routes through `CarPlayNavigationPolicy.trackIntent`:

- The live track opens Now Playing and is never restarted.
- A track in the playlist that is already the live queue is skipped to inside
  that queue, so the order after it survives.
- Anything else builds a fresh queue from that track.

Playback, shuffle, and in-queue skips all run through `PlaybackController`, so
the same behavior is available to the phone UI and the system transports. The
controller reports these failures by returning `false` and setting
`statusMessage` rather than throwing, so CarPlay checks the result and shows an
alert instead of navigating to a player that is not playing what was asked for.

The `Overplay` row resolves the current One True Playlist when it is tapped
rather than trusting the row it was drawn from, because the phone can change
that role while the menu is on screen.

There is no manual refresh. Visible lists are rebuilt from two triggers: the
playback observation below, and a `ModelContext.didSave` observation that
catches phone-side library changes — linking a playlist, changing the One True
Playlist, or a sync updating counts — which touch SwiftData without touching
playback state.

CarPlay browsing intentionally exposes only Active playlist contents. If the
user starts a Retired playlist context from iOS and then uses CarPlay, CarPlay
displays that current Retired context through the shared playback state, and
the shuffle row reshuffles that Retired order.

The shared Now Playing template installs direct track action buttons. Active
tracks expose Retire, Retired tracks expose Restore, and triage tracks expose
Promote where applicable. Its Up Next button returns to the root menu.

## Verification

The app target builds and unit tests cover CarPlay playlist summary ordering,
playable counts, template refresh targeting, the root/track navigation rules in
`CarPlayNavigationPolicy`, and the shared in-queue skip and shuffle-and-play
paths in `PlaybackController`. CarPlay simulator or device verification is
still required for scene launch, template presentation, and in-car playback
controls.
