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
- `CarPlayPlaylistSectionFactory` builds the shared Shuffle and Play action
  and track sections for all three playlist screens.
- `PlaybackController` owns the shared playlist-row action used by both
  CarPlay and iPhone/iPad, including resume, queue reuse, and replacement.
- `AppRuntime.shared` provides the shared model container, playback controller,
  authorization service, and remote command service used by both phone UI and
  CarPlay.

## Current CarPlay UI

The root template has no navigation-bar actions. It shows:

- A row for the One True Playlist, which opens its track list. There is no
  one-tap entry point above it: two similar-looking rows is one too many to
  disambiguate while driving.
- A Triage row for the shared intake bucket.
- A Retired row for locally retired tracks.

Each of these three track lists starts with a **Shuffle and Play** row above
tracks in their current local order. The action uses the shared controller's
playlist playback path, stops existing playback, selects a random starting track,
and enables MusicKit shuffle without changing the displayed playlist order. It
preserves the displayed Active or Retired scope and opens Now Playing on success.
It remains available when that playlist is already playing, matching the phone's
Shuffle and Play button. Empty lists show the action
disabled. Shuffle and repeat also remain available as Now Playing controls.

Tapping any track calls the same `PlaybackController.playPlaylist(_:startingAt:scope:settings:context:)`
action as the iPhone/iPad playlist UI. The shared action decides whether to
resume the current track, jump inside the matching live queue, or build a new
queue. CarPlay only presents and navigates; it has no separate track-selection
policy or fallback strategy.

The controller preserves the live queue for an in-queue selection and pauses
before a required replacement. It evaluates the outgoing session and publishes
the selected track through the same reconciliation path used by other playback
surfaces. Command failures remain in shared playback state and `statusMessage`.

There is no manual refresh. Visible lists are rebuilt from two triggers: the
playback observation below, and a `ModelContext.didSave` observation that
catches phone-side library changes — linking a playlist, changing the One True
Playlist, or a sync updating counts — which touch SwiftData without touching
playback state.

CarPlay exposes Active and Retired playback contexts through the same shared
playback state used by iOS.

The shared Now Playing template installs the system shuffle and repeat
buttons, which reflect and set MusicKit's own modes (`PLAY-004`). Repeat is an
intentional repeat-all/off toggle on both iPhone and CarPlay. These are followed by
the track actions chosen by `CarPlayNowPlayingActionPolicy`: Retire for an
active track, Restore for a retired one, and Promote for any triage track —
retired or not, because deciding to keep a track you had set aside is the
point of hearing it again. Its Up Next button returns to the root menu.

## Verification

The app target builds and unit tests cover CarPlay playlist summary ordering,
playable counts, Shuffle and Play placement and scope forwarding, empty-list
behavior, template refresh targeting, Now Playing action policy, and shared
playlist-row selection, in-queue skip, and playback-mode paths in
`PlaybackController`. The initial physical-device
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
