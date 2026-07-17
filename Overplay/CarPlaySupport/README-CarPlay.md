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
- `AppRuntime.shared` provides the shared model container, playback controller,
  authorization service, and remote command service used by both phone UI and
  CarPlay.

## Current CarPlay UI

The root CarPlay template shows:

- The main Overplay playlist in a `Main Playlist` section.
- Active triage playlists in a separate `Triage Playlists` section.

Selecting a playlist opens that playlist's Active track list. Selecting a track
starts playback through `PlaybackController` with that playlist as the active
queue, then opens `CPNowPlayingTemplate`. Standard CarPlay playback controls
are routed through the shared remote command and playback services.

CarPlay browsing intentionally exposes only Active playlist contents. If the
user starts a Retired playlist context from iOS and then uses CarPlay, CarPlay
displays that current Retired context through the shared playback state.

The shared Now Playing template installs direct track action buttons. Active
tracks expose Retire, Retired tracks expose Restore, and triage tracks expose
Promote where applicable.

## Verification

The app target builds and unit tests cover CarPlay playlist summary ordering and
playable counts. CarPlay simulator or device verification is still required for
scene launch, template presentation, and in-car playback controls.
