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
- `CarPlayListRenderer` retains list items and images, applies changed row
  properties, and replaces sections only when their structure changes.
- `PlaybackController` owns the shared playlist-row action used by both
  CarPlay and iPhone/iPad, including resume, queue reuse, and replacement.
- `AppRuntime.shared` provides the shared model container, playback controller
  and authorization service used by both phone UI and CarPlay.

## Current CarPlay UI

The root template has no navigation-bar actions. It shows:

- A large artwork card for the One True Playlist (an iOS 26 image-row card),
  which opens its track list. Cards have no playing indicator, so the card's
  subtitle reads "Now Playing" while it plays. There is no one-tap entry point
  above it: two similar-looking entries is one too many to disambiguate while
  driving.
- A headerless section with the Triage row ("X tracks from Y playlists") and a
  compact Retired row with a grey archive icon, matching the phone dashboard.
- Recent Deep Dives, when there are any: a strip of artwork tiles. A tile opens
  that album or artist; the title opens the full list.

Each of these three track lists starts with a **Shuffle and Play** row above
tracks in display order (newest-added first; Retired newest-retired first). The action uses the shared controller's
playlist playback path, stops existing playback, selects a random starting track,
and enables MusicKit shuffle without changing the displayed playlist order. It
preserves the displayed Active or Retired scope and opens Now Playing on success.
It remains available when that playlist is already playing, matching the phone's
Shuffle and Play button. Empty lists show the action
disabled. Shuffle and repeat also remain available as Now Playing controls.

Tapping any track calls the same `PlaybackController.playPlaylist(_:startingAt:scope:settings:context:)`
action as the iPhone/iPad playlist UI. The shared action decides whether to
resume the current track, select it in place in the live playback intent, or
start a new intent. CarPlay only presents and navigates; it has no separate
track-selection policy or fallback strategy.

Every resulting change is processed through the controller's single player
observation path, the same one used for the phone UI, Lock Screen, Control
Center and headset controls. A playback failure is shared state: CarPlay shows
one alert per failure episode with **Try Again**, which runs the same recovery
as Play on the phone. While the library is still restoring from iCloud, the root
template offers a **Resume** row for the saved playback intent.

There is no manual refresh. Relevant playback changes and library saves
invalidate value presentations; equality decides whether anything is published.
Unchanged presentations cause no CarPlay mutations. Counter and playing-indicator
changes update existing rows. Membership/order changes replace sections while
retaining surviving rows and artwork. Artwork loads only when its identity changes,
keeps the previous image while loading, and rejects stale completions. Explicit
surface re-entry retries failed artwork. Collage composition is maintained at
library lifecycle boundaries; reading a presentation never saves SwiftData.

System Now Playing, including transport, belongs to `ApplicationMusicPlayer`'s
host (`PLAY-016`). Overplay registers no remote commands and gates no controls on
its own belief. Now Playing retains its button array while the action layout
remains the same.

Diagnostics distinguish refresh requests (`carPlayRefreshRequested`) from actual
row/section, artwork, button-state and button-array writes. An idle menu may
receive requests but should produce no mutations.

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
acceptance pass was completed on 2026-09-08, before the October 2026
playback-core rewrite, which needs its own hardware pass (`TODO.md` §1). Repeat
the affected hardware checks after every CarPlay, playback, attribution or
MusicKit-mode change.

Current hardware follow-ups are tracked in GitHub: custom Promote, Retire, and
Restore controls are reported missing from Now Playing
([#22](https://github.com/xurble/overplay/issues/22)), the shuffle indicator is
reported to toggle repeatedly after a track transition
([#28](https://github.com/xurble/overplay/issues/28)), and the distinction between
Back and Up Next needs confirmation
([#27](https://github.com/xurble/overplay/issues/27)).
