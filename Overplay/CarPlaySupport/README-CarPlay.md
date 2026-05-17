# CarPlay Support

CarPlay support stays isolated so the iPhone app can compile and run before
the CarPlay entitlement is granted.

Once the entitlement is available:

1. Add a CarPlay scene configuration to the generated Info.plist.
2. Point that scene at `CarPlaySceneDelegate`.
3. Build templates in `CarPlayCoordinator` using the shared
   `PlaybackController` for Play Overplay, triage playlists, At Risk,
   Recently Evicted, and Now Playing actions.

The shared playback controller, now playing metadata, and remote command
handlers are already app-level services.
