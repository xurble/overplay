# Overplay Spec Implementation Audit

Compared `OVERPLAY_DESIGN_SPEC.md` with the implementation on 2026-06-24.

1. **[Specced But Not Implemented] Native Mac product surface.** The app target is iPhone/iPad only via `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"` and `TARGETED_DEVICE_FAMILY = "1,2"` in `Overplay.xcodeproj/project.pbxproj`.

2. **[Specced But Not Implemented] Mac-specific app behavior.** Mac menus, the standard Settings command, multiple windows, sortable tables, context menus, and media-key tailoring are not present. The shell is size-class based rather than a native Mac shell.

3. **[Specced But Not Implemented] Full dashboard summary.** `DashboardView` is mostly a playlist launcher. It does not show recently promoted count, triage queues with unreviewed or high-skip items, or direct play, sync, search, and history actions.

4. **[Specced But Not Implemented] Reset local playback state setting.** Settings has reset stats and nuke database actions, but no explicit reset-local-playback-state control.

5. **[Specced But Not Implemented] CarPlay at-risk tracks.** CarPlay does not expose an at-risk tracks section; its root template only lists Main Playlist and Triage Playlists.

6. **[Specced But Not Implemented] CarPlay recently evicted tracks.** CarPlay does not expose a recently evicted tracks section.

7. **[Specced But Not Implemented] Now Playing artwork metadata.** `NowPlayingMetadataService` publishes title, artist, album, duration, elapsed time, and playback rate, but not artwork.

8. **[Specced But Not Implemented] Direct denied-permission settings action.** Permission denial has guidance text, but no direct action to open system Settings.

9. **[Crucial Unspecified Implementation Detail] CloudKit-backed SwiftData configuration.** The app uses private CloudKit for SwiftData outside tests and an in-memory container during tests.

10. **[Crucial Unspecified Implementation Detail] Cached MusicKit playback data.** `TrackRecord` stores encoded MusicKit playback data so playback queues can be rebuilt from local records without refetching every track.

11. **[Crucial Unspecified Implementation Detail] Local playback order storage.** Local playback order is stored as JSON in `UserDefaults`, keyed by player ID and Apple Music playlist ID, with ordered local track IDs only.

12. **[Crucial Unspecified Implementation Detail] Playback identity aliasing.** `PlaybackIdentityStore` records MusicKit item aliases per local track to resolve current-entry identity drift across MusicKit, cached queue entries, and local records.

13. **[Crucial Unspecified Implementation Detail] Playback monitor cadence.** `PlaybackController` polls playback state every second and reconciles the player-reported current entry through shared playback state.

14. **[Crucial Unspecified Implementation Detail] Artwork cache implementation.** Artwork caching is actor-based, uses a JSON manifest, de-dupes in-flight downloads, tracks associated playlists and usage dates, and enforces a 250 MB budget.

15. **[Crucial Unspecified Implementation Detail] Album artwork theme cache.** The implementation includes an album-artwork theme cache and provider that derives UI colors from artwork using palette/OCR-style analysis.

16. **[Crucial Unspecified Implementation Detail] Album artwork theme warmup.** Sync can enqueue background theme warmup for newly inserted or changed artwork, with limited concurrency.

17. **[Crucial Unspecified Implementation Detail] Periodic sync timing.** Periodic sync uses a 10 second initial delay, 30 minute interval, and 30 minute freshness window.

18. **[Implemented Differently] Default eviction skip count.** The spec default is `evictAfterSkips = 3`, but `OverplaySettings` defaults to `6`.

19. **[Implemented Differently] Triage auto-eviction.** The spec says count-based eviction applies only to the One True Playlist. The implementation adds `triageAutoEvictsOnSkipCount`, allowing triage playlists to auto-evict when enabled.

20. **[Implemented Differently] Promotion source behavior.** The spec says promotion should leave the source triage playlist unchanged unless a future setting says otherwise. The implementation locally evicts the source triage item after a successful promotion.

21. **[Implemented Differently] Remote deletion scope.** The spec says manual eviction should attempt Apple Music removal if supported. The implementation only attempts remote deletion for managed Apple Music One True Playlist items.

22. **[Implemented Differently] Playlist-row eviction remote mutation.** Evicting from a playlist row is local-only and does not go through the current-track remote deletion path.

23. **[Implemented Differently] Search destination eligibility.** The spec says users can add tracks to any linked playlist. The implementation only offers active playlists that allow remote writes, excluding incoming-only playlists.

24. **[Implemented Differently] History presentation.** History is implemented as a filtered list everywhere, not as a Mac-style sortable/filterable table.

25. **[Implemented Differently] Settings reset model.** The implementation has “Reset All Local Overplay Stats” and “Nuke Database” actions rather than separate reset-local-playback-state and reset-shared-stats/history controls.
