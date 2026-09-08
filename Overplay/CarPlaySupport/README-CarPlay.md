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
- `CarPlayNavigationPolicy` decides what track rows do, free of CarPlay types
  so the rules are testable.
- `AppRuntime.shared` provides the shared model container, playback controller,
  authorization service, and remote command service used by both phone UI and
  CarPlay.

## Current CarPlay UI

The root template has no navigation-bar actions. It shows:

- A row for the One True Playlist, which opens its track list. There is no
  one-tap entry point above it: two similar-looking rows is one too many to
  disambiguate while driving.
- A separate section of the active triage playlists, which open the same
  track-list screen.

A track list contains the tracks in their current local order and nothing
else. Shuffle and repeat live on Now Playing as the system's own controls,
not as menu rows.

Tapping a track routes through `CarPlayNavigationPolicy.trackIntent`:

- The live track opens Now Playing and is never restarted.
- A track in the playlist that is already the live queue is skipped to inside
  that queue, so the order after it survives.
- Anything else builds a fresh queue from that track.

Playback and in-queue skips all run through `PlaybackController`, so
the same behavior is available to the phone UI and the system transports. The
controller reports these failures by returning `false` and setting
`statusMessage` rather than throwing, so CarPlay checks the result and shows an
alert instead of navigating to a player that is not playing what was asked for.

There is no manual refresh. Visible lists are rebuilt from two triggers: the
playback observation below, and a `ModelContext.didSave` observation that
catches phone-side library changes — linking a playlist, changing the One True
Playlist, or a sync updating counts — which touch SwiftData without touching
playback state.

CarPlay browsing intentionally exposes only Active playlist contents. If the
user starts a Retired playlist context from iOS and then uses CarPlay, CarPlay
displays that current Retired context through the shared playback state.

The shared Now Playing template installs the system shuffle and repeat
buttons, which reflect and set MusicKit's own modes (`PLAY-004`). Repeat is an
intentional repeat-all/off toggle on both iPhone and CarPlay. These are followed by
the track actions chosen by `CarPlayNowPlayingActionPolicy`: Retire for an
active track, Restore for a retired one, and Promote for any triage track —
retired or not, because deciding to keep a track you had set aside is the
point of hearing it again. Its Up Next button returns to the root menu.

## Verification

The app target builds and unit tests cover CarPlay playlist summary ordering,
playable counts, template refresh targeting, track navigation rules in
`CarPlayNavigationPolicy`, Now Playing action policy, and the shared in-queue
skip and playback-mode paths in `PlaybackController`. The initial physical-device
acceptance pass was completed on 2026-09-08. Repeat the affected hardware checks
after every CarPlay, playback, queue-correlation, remote-command, or MusicKit-mode
change.

Current hardware follow-ups are tracked in GitHub: custom Promote, Retire, and
Restore controls are reported missing from Now Playing
([#22](https://github.com/xurble/overplay/issues/22)), the shuffle indicator is
reported to toggle repeatedly after a track transition
([#28](https://github.com/xurble/overplay/issues/28)), and the distinction between
Back and Up Next needs confirmation
([#27](https://github.com/xurble/overplay/issues/27)).
