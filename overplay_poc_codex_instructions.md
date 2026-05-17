# Overplay iOS Proof-of-Concept Build Instructions for Codex

## Project summary

Build a proof-of-concept iOS app called **Overplay**.

Overplay is a focused Apple Music companion app for managing one user-selected Apple Music playlist. The intended use case is a main dump-everything playlist, such as the user's playlist named **Overplay**. The app should play that playlist, track the user's own skip/playthrough behaviour, and eventually remove or quarantine tracks that are skipped too many times.

The first proof of concept must prove four things:

1. The app can authenticate with Apple Music / MusicKit.
2. The app can let the user choose a monitored Apple Music library playlist.
3. The app can play tracks from that playlist with a polished Now Playing screen.
4. The app can track skips/playthroughs using its own local rules and mark tracks for eviction.

Apple Music playlist removal should be treated as a spike/risk item. If direct track removal from an existing Apple Music library playlist is not available or proves unreliable, implement local “evicted” state and hide evicted songs from Overplay playback instead. Do not block the whole proof of concept on playlist mutation.

---

## Assumptions and constraints

- Target platform: iOS.
- Minimum iOS target: iOS 17 unless the project template defaults higher.
- Language: Swift.
- UI framework: SwiftUI.
- Persistence: SwiftData for local proof-of-concept state.
- Apple Music integration: MusicKit first. Use Apple Music API only where MusicKit cannot do the job.
- Playback: use `ApplicationMusicPlayer` from MusicKit unless a technical limitation forces another route.
- CarPlay: include a clear project structure and placeholder CarPlay scene where possible, but the proof of concept should still compile and run without the CarPlay entitlement. The app should be designed so CarPlay can be enabled once Apple grants the entitlement.
- Do not implement accounts, servers, subscriptions, analytics, push notifications, or non-Apple music services in this proof of concept.

---

## Important API risks to investigate early

Codex should prioritise the following spikes before spending time polishing secondary screens:

### 1. Apple Music authorisation

Confirm that the app can request Apple Music access and detect whether the user has permission and Apple Music subscription capabilities.

Expected states:

- Not determined
- Denied / restricted
- Authorised
- Authorised but no active subscription / cannot play catalogue content

The app should show useful UI for each state.

### 2. Reading user library playlists

Confirm that the app can fetch the user's Apple Music library playlists and display them in a picker.

The picker should favour a playlist named `Overplay` if present, but the user must be able to select any playlist.

### 3. Playing the selected playlist

Confirm that the app can build a playback queue from the selected playlist's tracks and start playback.

### 4. Mutating the selected playlist

Test whether the app can remove a track from the selected Apple Music library playlist.

Treat this as optional for the POC. If removal is unavailable, implement local eviction instead:

- Mark the track as evicted in SwiftData.
- Exclude evicted tracks from the queue that Overplay creates.
- Show evicted tracks in an Eviction History screen.
- Add a Restore button that clears the local evicted flag.

---

## Required app capabilities and configuration

Create an Xcode SwiftUI iOS app project named `Overplay`.

Add these capabilities / configuration items:

1. **MusicKit capability** in the Apple Developer portal and Xcode target capabilities.
2. `NSAppleMusicUsageDescription` in Info.plist.

Suggested usage string:

```text
Overplay needs access to your Apple Music library so it can play and manage your selected playlist.
```

3. Background audio mode may be useful later, but only enable it in the POC if playback requires it and it does not complicate development.
4. CarPlay entitlement is not expected to be available during the POC. Keep CarPlay code isolated behind compile-time or runtime availability so the main iOS app builds without entitlement issues.

---

## High-level product behaviour

### User flow

1. User opens Overplay.
2. App checks Apple Music authorisation.
3. If needed, user taps **Connect Apple Music**.
4. App loads the user's Apple Music library playlists.
5. User chooses the monitored playlist.
6. App syncs tracks from that playlist into local SwiftData tracking records.
7. User taps **Play Overplay**.
8. Now Playing screen appears with album artwork, title, artist, album, skip count, and controls.
9. When the user skips a song before the configured threshold, Overplay increments that track's local skip count.
10. When the track reaches the configured eviction threshold, Overplay evicts it.
11. If direct Apple Music playlist removal is available, remove it from the playlist. Otherwise mark it locally evicted and exclude it from future Overplay queues.
12. If the user listens past the playthrough threshold, optionally reset the skip count.

---

## Required screens

### 1. Launch / Permissions screen

Purpose: handle Apple Music permission and subscription readiness.

Show:

- App name: `Overplay`
- Short tagline: `Keep your main playlist fresh.`
- Apple Music connection status
- Button: `Connect Apple Music`
- If permission denied, show instructions to enable Media & Apple Music permission in Settings.
- If Apple Music subscription/capability is insufficient, show a non-crashing explanation.

Acceptance criteria:

- The screen does not crash if MusicKit is unavailable or unauthorised.
- It transitions to playlist selection after successful authorisation.

---

### 2. Playlist selection screen

Purpose: choose the single monitored Apple Music playlist.

Show:

- List of user library playlists.
- Playlist title.
- Track count if available.
- Search/filter field for local filtering of playlists.
- Highlight or pin a playlist named `Overplay` when present.
- Button: `Use This Playlist`.

Persist selected playlist ID and playlist name in app settings.

Acceptance criteria:

- User can choose a playlist.
- Selected playlist persists across app launches.
- User can change playlist later in Settings.

---

### 3. Main dashboard

Purpose: show the monitored playlist status and entry points.

Show:

- Selected playlist name.
- Number of tracks known locally.
- Number of locally evicted tracks.
- Number of tracks currently at risk.
- Button: `Play Overplay`.
- Button: `Sync Playlist`.
- Button: `Search Apple Music`.
- Button/link: `Settings`.
- Button/link: `Eviction History`.

“At risk” means tracks whose skip count is one below the eviction threshold or higher, excluding already evicted tracks.

Acceptance criteria:

- Dashboard loads even before any sync.
- Sync creates or updates local track records.
- Evicted tracks are excluded from playable count.

---

### 4. Now Playing screen

Purpose: attractive playback UI and skip tracking.

This is the most important visible screen.

Design direction:

- Large album artwork.
- Blurred or gradient-like background derived from artwork if straightforward; otherwise use a tasteful dark material background.
- Track title, artist, album.
- Progress bar.
- Current elapsed time and total duration where available.
- Skip count indicator, e.g. `Skips: 2 / 3`.
- Eviction status if applicable.
- Large playback controls.

Required controls:

- Previous track
- Play / pause
- Next track
- Shuffle toggle
- Repeat mode toggle
- “Keep” / reset skip count
- “Evict now” for testing

The standard media controls should call into a central playback controller rather than each view implementing playback logic.

Acceptance criteria:

- Artwork is shown for current track where available.
- Play/pause state updates correctly.
- Next button triggers skip-evaluation for the outgoing track.
- Previous button should not normally count as a skip unless the current track has played for a configurable minimum period and is below the skip threshold. Prefer not to count previous as a skip in the POC.
- “Keep” resets skip count and optionally marks the track as protected.
- “Evict now” marks the track evicted immediately and moves to the next playable track.

---

### 5. Settings screen

Purpose: configure the initial eviction algorithm.

Settings:

- Monitored playlist.
- Evict after X skips.
  - Default: 3.
  - Minimum: 1.
  - Maximum: 20.
- Skip threshold percentage.
  - Default: 50%.
  - Meaning: if the user moves away from the track before this percentage, count as a skip.
  - Example: threshold 50 means skipping after 30% counts, skipping after 75% does not.
- Minimum listening time before a skip can count.
  - Default: 10 seconds.
  - Prevents accidental immediate skips from counting.
- Playthrough threshold percentage.
  - Default: 90%.
- Playthrough resets skip count.
  - Default: on.
- Protect kept tracks from eviction.
  - Default: off for POC unless easy.
- Reset all local Overplay stats.
  - Destructive confirmation required.

Acceptance criteria:

- Settings persist across app launches.
- Changing thresholds affects future skip/playthrough decisions.
- Reset all stats clears local skip/playthrough/eviction state but does not delete Apple Music playlist content.

---

### 6. Eviction History screen

Purpose: show what has been evicted and allow undo.

Show:

- Track artwork thumbnail.
- Title.
- Artist.
- Date evicted.
- Reason, e.g. `3 skips before 50%`.
- Button: `Restore`.

Restore behaviour:

- If eviction is local only, clear `evictedAt` and allow it back into future queues.
- If actual Apple Music removal was implemented, attempt to add the track back to the monitored playlist, then clear local eviction state if successful.

Acceptance criteria:

- History survives app restart.
- Restore is possible for local evictions.

---

### 7. Search Apple Music screen

Purpose: search Apple Music catalogue and add songs to the monitored playlist or local queue.

Use MusicKit catalogue search if available.

Show:

- Search field.
- Results list with artwork, title, artist, album.
- Button: `Add`.

Add behaviour:

- Preferred: add the track to the selected Apple Music library playlist.
- If adding to playlist is unavailable, show a clear non-fatal message.
- After successful add, sync the playlist again or insert/update local track state.

Acceptance criteria:

- Searching does not crash with empty queries, network errors, or missing Apple Music subscription.
- Add operation reports success/failure clearly.

---

## CarPlay proof-of-concept requirements

CarPlay is a secondary objective for the POC.

Implement the code structure so CarPlay can be enabled later with minimal refactoring.

Required architecture:

- A shared playback controller used by both iPhone UI and CarPlay UI.
- Now Playing metadata published through `MPNowPlayingInfoCenter` where appropriate.
- Remote command handlers through `MPRemoteCommandCenter` for play, pause, next, previous, shuffle and repeat where practical.

If implementing actual CarPlay templates is possible without entitlement in development, create:

- A CarPlay scene delegate.
- A basic list template with:
  - Play Overplay
  - At Risk
  - Recently Evicted
- A Now Playing template using the system CarPlay now playing UI.

If entitlement blocks this, create a `CarPlaySupport` folder with clearly stubbed files and comments explaining where to enable once entitlement is granted.

Acceptance criteria:

- Main iOS app compiles without CarPlay entitlement.
- Playback controller has no direct dependency on SwiftUI views.
- Remote commands update playback when app is active/backgrounded where supported.

---

## Eviction algorithm v1

Implement this exact first version.

### Definitions

A `TrackPlaySession` begins when a new track becomes current.

Store:

- Track ID.
- Session start time.
- Last observed playback time.
- Track duration.
- Whether skip/playthrough has already been evaluated for this session.

### Skip decision

When the user manually moves away from the current track using Next, or when the playback item changes unexpectedly, evaluate the outgoing track:

A skip is counted when all are true:

1. The track was not already evaluated for this play session.
2. The track is not locally evicted.
3. The track is not protected.
4. The user listened for at least `minimumSkipListeningSeconds`.
5. Playback progress percentage is less than `skipThresholdPercentage`.
6. The transition was not caused by natural completion.

Default values:

```swift
skipThresholdPercentage = 50
minimumSkipListeningSeconds = 10
evictAfterSkips = 3
playthroughThresholdPercentage = 90
playthroughResetsSkipCount = true
```

### Playthrough decision

A playthrough is counted when progress reaches or exceeds `playthroughThresholdPercentage` or natural completion is detected.

If `playthroughResetsSkipCount == true`, set `skipCount = 0` for that track.

### Eviction decision

After incrementing skip count:

```swift
if skipCount >= evictAfterSkips && !protected {
    evict(track)
}
```

Eviction should:

1. Set `evictedAt`.
2. Store `evictionReason`.
3. Remove from current queue or skip past it.
4. Attempt Apple Music playlist removal only if implemented and safe.

---

## Suggested SwiftData models

Codex may adjust exact syntax to match current SwiftData best practice.

### `OverplaySettings`

Fields:

- `id: UUID`
- `selectedPlaylistID: String?`
- `selectedPlaylistName: String?`
- `evictAfterSkips: Int`
- `skipThresholdPercentage: Double`
- `minimumSkipListeningSeconds: Double`
- `playthroughThresholdPercentage: Double`
- `playthroughResetsSkipCount: Bool`
- `protectKeptTracks: Bool`
- `createdAt: Date`
- `updatedAt: Date`

There should only be one settings record. Provide a repository method that creates the default settings record if missing.

### `TrackedTrack`

Fields:

- `id: String`
  - Use the best stable Apple Music identifier available.
  - Prefer library ID for library playlist entries and also store catalog ID if available.
- `catalogID: String?`
- `libraryID: String?`
- `playlistEntryID: String?`
- `playlistID: String?`
- `title: String`
- `artistName: String`
- `albumTitle: String?`
- `artworkURLTemplate: String?`
- `durationSeconds: Double?`
- `skipCount: Int`
- `playthroughCount: Int`
- `lastPlayedAt: Date?`
- `lastSkippedAt: Date?`
- `evictedAt: Date?`
- `evictionReason: String?`
- `protected: Bool`
- `lastSeenInPlaylistAt: Date?`
- `createdAt: Date`
- `updatedAt: Date`

### `PlaybackEvent`

Use this for debugging the POC.

Fields:

- `id: UUID`
- `trackID: String`
- `eventType: String`
  - `started`
  - `skipCounted`
  - `skipIgnored`
  - `playthrough`
  - `evicted`
  - `restored`
- `positionSeconds: Double?`
- `durationSeconds: Double?`
- `progressPercentage: Double?`
- `reason: String?`
- `createdAt: Date`

---

## Suggested app architecture

Use a simple MVVM/service structure.

```text
Overplay/
  App/
    OverplayApp.swift
    AppRouter.swift
  Models/
    OverplaySettings.swift
    TrackedTrack.swift
    PlaybackEvent.swift
  Services/
    MusicAuthorizationService.swift
    PlaylistSyncService.swift
    PlaybackController.swift
    EvictionEngine.swift
    SearchService.swift
    NowPlayingMetadataService.swift
    RemoteCommandService.swift
  Persistence/
    SettingsRepository.swift
    TrackRepository.swift
    EventRepository.swift
  Views/
    PermissionView.swift
    PlaylistSelectionView.swift
    DashboardView.swift
    NowPlayingView.swift
    SettingsView.swift
    EvictionHistoryView.swift
    SearchMusicView.swift
    Components/
      ArtworkView.swift
      PlaybackControlsView.swift
      StatCardView.swift
  CarPlaySupport/
    CarPlaySceneDelegate.swift
    CarPlayCoordinator.swift
    README-CarPlay.md
```

Keep Apple Music / MusicKit calls out of SwiftUI views. Views should call view models or services.

---

## Service responsibilities

### `MusicAuthorizationService`

Responsibilities:

- Request Apple Music authorisation.
- Check current authorisation status.
- Check capabilities/subscription where available.
- Expose simple state to UI.

Example state:

```swift
enum MusicAccessState {
    case unknown
    case notDetermined
    case denied
    case restricted
    case authorised(canPlayCatalogContent: Bool)
    case error(String)
}
```

### `PlaylistSyncService`

Responsibilities:

- Fetch user library playlists.
- Fetch tracks for selected playlist.
- Upsert `TrackedTrack` rows.
- Mark tracks no longer seen in playlist as missing, but do not delete local stats.
- Exclude locally evicted tracks from playback queue.

### `PlaybackController`

Responsibilities:

- Own `ApplicationMusicPlayer.shared` or equivalent.
- Set playback queue from selected playlist tracks excluding locally evicted tracks.
- Start/pause/resume playback.
- Next/previous.
- Shuffle/repeat.
- Publish current track state for SwiftUI.
- Create/evaluate play sessions.
- Notify `EvictionEngine` when track changes or user skips.

Suggested published state:

```swift
struct CurrentPlaybackState {
    var trackID: String?
    var title: String
    var artist: String
    var album: String?
    var artworkURL: URL?
    var duration: TimeInterval?
    var elapsed: TimeInterval
    var isPlaying: Bool
    var shuffleEnabled: Bool
    var repeatMode: RepeatMode
    var skipCount: Int
    var evictAfterSkips: Int
}
```

### `EvictionEngine`

Responsibilities:

- Apply the skip/playthrough rules.
- Increment/reset skip counts.
- Mark tracks evicted.
- Write debug `PlaybackEvent` rows.
- Return an action to playback controller, e.g. `.continue`, `.skipCurrent`, `.rebuildQueue`.

### `SearchService`

Responsibilities:

- Search Apple Music catalogue.
- Return lightweight result models.
- Add selected track to monitored playlist where possible.

### `NowPlayingMetadataService`

Responsibilities:

- Publish current metadata to `MPNowPlayingInfoCenter`.
- Update artwork/title/artist/progress.

### `RemoteCommandService`

Responsibilities:

- Register remote command handlers.
- Forward commands to `PlaybackController`.
- Avoid retain cycles.
- Clean up handlers as appropriate.

---

## Edge cases to handle

- User has no Apple Music permission.
- User denies permission.
- User has permission but no Apple Music subscription.
- User has no playlists.
- Selected playlist is deleted or renamed.
- Playlist contains local-only/unavailable/cloud items that MusicKit cannot play.
- Track has no artwork.
- Track has no duration.
- Same song appears twice in playlist.
- App is killed and relaunched mid-track.
- User taps Next immediately after a song starts.
- User scrubs near the end and skips.
- User skips after threshold; should not count as skip.
- Natural completion should be playthrough, not skip.
- Network failure while searching or syncing.
- Apple Music playlist mutation fails.

For duplicate songs, POC can track by song ID, not playlist occurrence. Add a code comment that playlist-entry-level tracking may be needed later.

---

## Visual design direction

The POC should look like a real app, not a debug utility.

Use:

- SwiftUI.
- Large typography for track title.
- Album artwork as the visual centrepiece.
- Rounded cards.
- Material backgrounds where appropriate.
- A restrained dark-first design.
- Clear tappable controls.

Now Playing layout:

```text
[Large artwork]

Track Title
Artist • Album

0:42 ━━━━━━━━━━━━━━━ 3:51

Skips: 2 / 3

[shuffle] [previous] [play/pause] [next] [repeat]

[Keep] [Evict Now]
```

Dashboard layout:

```text
Overplay
Keep your main playlist fresh.

Playlist: Overplay
Playable tracks: 142
At risk: 7
Evicted: 18

[Play Overplay]
[Sync Playlist]

At Risk
- Song A — 2 / 3 skips
- Song B — 2 / 3 skips
```

---

## Build milestones

### Milestone 1 — Project skeleton

- Create SwiftUI project.
- Add SwiftData models.
- Add settings repository with defaults.
- Add placeholder screens and navigation.
- App launches cleanly.

### Milestone 2 — Apple Music authorisation

- Add MusicKit capability/configuration.
- Implement permission screen.
- Request authorisation.
- Display current access state.

### Milestone 3 — Playlist selection and sync

- Fetch user library playlists.
- Let user select playlist.
- Persist selection.
- Fetch playlist tracks.
- Upsert local `TrackedTrack` rows.
- Show dashboard counts.

### Milestone 4 — Playback and Now Playing

- Create playback queue from selected playlist.
- Exclude locally evicted tracks.
- Implement play/pause/next/previous.
- Show current track metadata and artwork.
- Show progress.
- Add shuffle/repeat toggles if supported by chosen player API.

### Milestone 5 — Skip/playthrough tracking

- Implement session tracking.
- Count skip on manual next before threshold.
- Ignore skip after threshold.
- Reset skips after playthrough if setting enabled.
- Show skip count on Now Playing.
- Write debug playback events.

### Milestone 6 — Local eviction

- Evict when skip count reaches threshold.
- Exclude evicted tracks from queue.
- Add Eviction History screen.
- Add Restore.
- Add Evict Now and Keep buttons.

### Milestone 7 — Search and add

- Implement Apple Music catalogue search.
- Show results.
- Add to monitored playlist if API supports it.
- Resync after add.
- If add is not possible, show clear error.

### Milestone 8 — CarPlay-ready architecture

- Add Now Playing metadata service.
- Add remote command service.
- Add CarPlaySupport folder with stubbed or working scene delegate.
- Document entitlement steps in `CarPlaySupport/README-CarPlay.md`.

---

## Testing checklist

Manual tests are acceptable for the POC.

### Authorisation

- Fresh install asks for Apple Music permission.
- Denying permission shows helpful message.
- Granting permission proceeds to playlist selection.

### Playlist sync

- Playlist named Overplay appears.
- User can select it.
- Tracks appear in local stats.
- Sync can be run multiple times without duplicating tracks.

### Playback

- Play starts from monitored playlist.
- Album art appears.
- Next moves to next track.
- Previous moves back or restarts depending player behaviour.
- Play/pause state updates.

### Skip rules

With defaults: evict after 3 skips, skip threshold 50%, minimum listen 10 seconds.

- Listen 12 seconds, skip before 50%: skip count increments.
- Skip immediately before 10 seconds: skip count does not increment.
- Skip after 50%: skip count does not increment.
- Listen past 90%: playthrough increments.
- If playthrough reset enabled: skip count resets to 0.
- After 3 counted skips: track is evicted.
- Evicted track no longer appears in generated playback queue.
- Restore makes it playable again.

### Search

- Search for a known song.
- Results show artwork/title/artist.
- Add either succeeds or fails gracefully.

### Persistence

- Close and reopen app.
- Selected playlist remains selected.
- Skip counts remain.
- Eviction history remains.
- Settings remain.

---

## What not to build in the POC

Do not build these yet:

- Android app.
- Spotify support.
- Social sharing.
- User accounts.
- Backend server.
- Subscription/paywall.
- Machine-learning recommendations.
- Complex smart playlist rules.
- Apple Watch app.
- iCloud sync between devices.
- Full production CarPlay entitlement flow beyond code structure and documentation.

---

## Deliverables

At the end of the POC, the repository should contain:

1. A compiling iOS SwiftUI app named `Overplay`.
2. MusicKit authorisation flow.
3. Playlist picker for Apple Music library playlists.
4. Local SwiftData tracking for playlist tracks.
5. Attractive Now Playing screen.
6. Playback controls: play, pause, next, previous, shuffle, repeat where supported.
7. Skip/playthrough tracking using Overplay's own rules.
8. Local eviction and restore.
9. Search screen for Apple Music songs.
10. Best-effort add-to-playlist implementation.
11. CarPlay-ready shared playback architecture.
12. Notes in the README describing what playlist mutations are and are not possible with current APIs.

---

## README notes Codex should add to the repo

Include a top-level `README.md` with:

- What Overplay does.
- How to enable MusicKit in Apple Developer/Xcode.
- Required Info.plist keys.
- Known limitations.
- Whether direct playlist track removal worked during the spike.
- How local eviction works.
- CarPlay entitlement notes.

Include this warning:

```text
Overplay tracks its own skip/playthrough state. It does not rely on Apple Music's global play count or skip count.
```

Also include:

```text
If Apple Music does not allow direct removal of tracks from an existing library playlist, Overplay uses local eviction: evicted songs remain in Apple Music but are excluded from Overplay playback.
```

---

## Implementation notes for Codex

- Prefer simple, working code over abstraction.
- Keep services small and testable.
- Avoid putting MusicKit calls directly inside SwiftUI view bodies.
- Use async/await for MusicKit/network calls.
- Use `@MainActor` for UI-facing observable objects.
- Log errors clearly.
- Do not crash on missing Apple Music data.
- Use placeholder artwork where artwork is missing.
- Add comments around any MusicKit API uncertainty.
- If an API does not exist or behaves differently, implement the closest working fallback and document it in README.

---

## POC success definition

The proof of concept is successful if a user can:

1. Connect Apple Music.
2. Select their `Overplay` playlist.
3. Play it inside the app.
4. See a polished Now Playing screen.
5. Skip tracks and watch the skip count increase.
6. Have a track locally evicted after the configured number of skips.
7. Restore an evicted track.
8. Search Apple Music and attempt to add a song to the monitored playlist.

Direct Apple Music playlist removal is a bonus, not a requirement for POC success.
