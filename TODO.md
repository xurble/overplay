# Overplay Roadmap

This is the single living planning document for Overplay. Read it alongside
`OVERPLAY_DESIGN_SPEC.md`, which specifies current behaviour and product
invariants, and `PLAYBACK_RELIABILITY_FINDINGS.md`, which records the playback
stall investigation.

Overplay is the owner's daily music player, and this roadmap is now the plan
for releasing it. It follows the spec's **Product priorities**: reliable
player, then CarPlay and Siri, then playlist management, then statistics.
Reorder it when product goals change or new evidence changes the risk.

## Where things stand (2026-10-18)

- **Playback:** the rewrite (#61, PR #62) is merged and passed acceptance on
  the owner's iPhone on 2026-10-06. Apple Music stalls are contained rather
  than cured: a stuck player (#84, PR #91) and a play that never starts
  (PR #97) are reported as failures on every surface, with recovery on Play
  or advice to force-quit. Why the player stalls is still open (#90).
- **CarPlay:** in daily use, but the rewrite's CarPlay hardware checks were
  never run, and the shuffle button still flickers (#28).
- **Siri:** minimal Siri is built (2026-10-19, spec **Siri**): play the One
  True Playlist or the Inbox, promote, retire and undo. Not yet checked by voice
  on a device.
- **Playlist management:** One True Playlist, the Inbox and Retired, global track
  ownership, sync and rebuild are done (#34, #36, #39–#41, #64–#75). MusicKit
  can edit only playlists Overplay created, and the Mac cannot write
  playlists at all.
- **Statistics:** the listen ledger is done, with one displayed play count
  that never falls below Apple's. Six accepted limitations are listed in the
  spec's Known Defects.
- **Since the last roadmap:** Play Album and Play Artist (`PLAY-018`), Recent
  Deep Dives (`PLAY-019`), Library browsing (`LIB-001`), iPhone Duo and iPad
  layouts, and the Mac Catalyst build with menus, a Settings window and a
  title-bar mini player.

## Release path

1. **Internal TestFlight:** a distribution-signed build on the owner's own
   devices, against Production CloudKit (Milestone 1).
2. **Device acceptance:** CarPlay hardware pass and the standing playback gate
   (Milestone 2).
3. **v1 features:** minimal Siri, a reworked search, beta settings
   (Milestone 3).
4. **External TestFlight**, then **App Store** (Milestone 4).

The Mac helper (`HELPER-*`) is unsandboxed and scripts Music, so it cannot
ship through the App Store. It is post-v1 work and would ship separately,
Developer ID–signed and notarized.

## Milestone 1: Internal TestFlight

### 1.1 Keep the test suite green

Green again on 2026-10-18 (c521d73: 905 tests, serial, iPad simulator). The
play-count wording and error-message expectations were updated, a refresh no
longer counts a floor-raised item twice, and `appleFloor` and
`UserFacingError` have their own tests. Still to do:

- Add focused tests for the library cache (`LibraryCache`) and library
  playback's choice of this device's own copies (2ed2470 was checked by eye
  only).
- Run the full `commands.check` suite serially (`-parallel-testing-enabled NO`)
  before each TestFlight build.

### 1.2 Privacy manifest

Add `PrivacyInfo.xcprivacy` to the app target. App Store Connect rejects
builds that use required-reason APIs without declaring them. Overplay uses at
least UserDefaults/`AppStorage` and, since PR #97, disk space
(`volumeAvailableCapacityForImportantUsage`). Audit file timestamp and system
boot time APIs too. Declare no tracking and no collected data, unless the
audit finds otherwise.

### 1.3 CloudKit Production schema

Deploy every SwiftData record type to the Production CloudKit environment,
including `RecentCollectionRecord` (`PLAY-019`). TestFlight and App Store
builds use Production. Deploying a schema does not copy records, so the
owner's Development data will not appear (spec: **Datastore generation 2**).
Verify a cross-device restore in Production before claiming it works.

### 1.4 Decide on data preservation

The owner's listening history now matters, which is the decision the
pre-release data policy in `AGENTS.md` defers. Choose one:

- **Carry the data forward:** freeze the schema, export or migrate the owner's
  Development data into Production, and add a SwiftData migration path for
  every later model change.
- **One deliberate reset:** start Production empty at the first TestFlight
  build, document that beta testers start fresh, and freeze the schema from
  then on.

Either way, once the first external tester installs, schema changes need a
migration. Update the **Pre-release Data Policy** in `AGENTS.md` to match the
decision.

### 1.5 Distribution signing and metadata

- Confirm that the CarPlay audio entitlement
  (`com.apple.developer.carplay-audio`) is granted for distribution, not only
  development, and appears on the App Store provisioning profile.
- Confirm the MusicKit App Service and the iCloud container for the release
  bundle ID (`Config/Local.xcconfig`).
- Set `ITSAppUsesNonExemptEncryption` to `NO` in both Info.plists, unless that
  turns out to be untrue.
- Settle versioning: the app target's `MARKETING_VERSION` is `2026`, while the
  test targets use `1.0`.
- Background modes: `audio`, `fetch` and `remote-notification` (CloudKit
  pushes, #54) are declared. Confirm on device whether `audio` is needed for
  MusicKit and CarPlay. Keep the other two.

### 1.6 Decide which diagnostics ship

Settings currently exposes Apple Music Call Activity and its shared activity
log, the diagnostic **Mirror Now Playing from Overplay**, and the sysdiagnose
reminder on a stuck player. Keep them for TestFlight, where they are how
testers report stalls. Before the App Store, decide whether the mirror and the
raw activity report move behind a hidden or Troubleshooting-only entry.

## Milestone 2: Device Acceptance

### 2.1 CarPlay hardware pass

Run once on a real head unit, after Milestone 1's build is installed, and
record the results on GitHub. Each item is a release blocker if it fails.

- CarPlay Now Playing follows the playing track with the diagnostic mirror
  off. If it does not (a reported iOS 27 issue, forum thread 847151), compare
  with **Mirror Now Playing from Overplay** on, and record the result in the
  spec before changing the default.
- The custom Promote, Retire and Restore buttons appear and work (#22 was
  closed before the rewrite), and are disabled for a track Overplay cannot
  attribute.
- The shuffle and repeat buttons show MusicKit's real modes and do not
  flicker after a track change (#28, still seen 2026-10-07). First use the
  activity log to tell whether only the button flickers or MusicKit's mode
  really changes. Do not hide a real mode change with debouncing. On the same
  drive, check the `loaded=` counts when a shuffle tap does not take.
- Back goes up one level and Up Next returns to the root menu (#27). If the
  two are indistinguishable on hardware, remove Up Next.
- Lock Screen, Control Center, headset and CarPlay agree with the app after
  rapid Next presses.
- Play Album and Play Artist (`PLAY-018`) from the CarPlay album/artist button,
  and Recent Deep Dives (`PLAY-019`) from the CarPlay root, including Back from
  Now Playing.
- Cold launch before iCloud restoration: CarPlay offers Resume and plays.

### 2.2 Standing playback gate

Repeat the affected parts after every change to playback, attribution,
MusicKit modes, CarPlay templates, suspended-playback reconciliation or
counting.

For every action origin (SwiftUI, CarPlay, and the system transport controls)
and for natural track advancement, the current track, queue context, play
state, position, outgoing-track statistics and history, active-playlist
projection, restore state, CarPlay presentation and system Now Playing must
converge without navigation, relaunch, template reset, sync or manual refresh.
A stale surface is a release-blocking regression even when the audio is right.

Counting checks:

- Skip at less than 10 seconds: no skip counted.
- Skip at about 30%: skip counted once.
- Skip at about 70%: neither skip nor playthrough.
- Natural completion: playthrough counted once.
- Lock the phone, let several tracks play, then unlock: no phantom skips or
  missing-track misattribution.
- Pause mid-track, force-quit, relaunch, then play another playlist: no phantom
  event for the restored track.
- At the final track, repeat off stops after crediting the playthrough; repeat
  all wraps under MusicKit control; shuffle state remains unchanged.
- Retire the current track: playback advances and remote removal is attempted
  according to policy.

Library and playlist checks:

- Manual-add a searched track, then sync: one row, counts intact.
- Promote a bucket track, then sync the contributing playlist and the One True
  Playlist: one One True Playlist row.
- Two devices on one account: playback stays independent, shared counts
  converge without duplicate rows, and both show the same Recent Deep Dives.
- Untracked songs from Play Album, Play Artist and Library offer Add to the Inbox
  and Add to One True Playlist and are not counted. Check Add to One True
  Playlist on iPhone or iPad; the Mac cannot write playlists.

Failure checks:

- Airplane mode mid-track: every surface shows the failure, Pause still works,
  and Play recovers without restarting the phone.
- A play that never starts (PR #97) is reported, on low bandwidth or with
  storage nearly full. Not yet seen under real conditions.
- Relaunch while music is playing: Overplay re-attaches without restarting the
  queue.

### 2.3 Suspended playback on device

- Validate delayed MusicKit counter propagation after a long suspended span,
  including shuffle and unavailable metadata (#9).
- Check whether Apple's play count and last-played date update on iPhone after
  Overplay plays a song (FB17675148 reports they do not on the Mac).

Skips remain witnessed-only; ambiguous or unsampled playback can under-count.

### 2.4 Mac Catalyst playback

Run live playback on My Mac (Mac Catalyst): start, select, transport,
shuffle/repeat, Library playback, the Settings window and the title-bar mini
player. Watch for Soor's reported bug where macOS returns the system player's
queue instead of the app player's (`PLAYBACK_RELIABILITY_FINDINGS.md`).

### 2.5 Report the stall to Apple

File a Feedback report for `prepareToPlay` never returning, with the activity
log, a sysdiagnose and forum thread 825433, and record the FB number in the
spec's Known Defects. The open questions and what to collect next time are in
#90 and `PLAYBACK_RELIABILITY_FINDINGS.md`.

## Milestone 3: v1 Features

### 3.1 Minimal Siri

Product priority 2. **Built 2026-10-19** (spec **Siri**, `SIRI-001`,
`SIRI-002`; **Undo Promote or Retire**, `MUT-003`; `PLAY-020`): Play One True
Playlist ("Play Overplay"), Play the Inbox, Promote, Retire and Undo, each a thin
adapter over the shared action, with tests at the shared entry points. The
iOS 27 audio schemas need iOS 27 and wait for Fuller Siri.

Remaining:

- Verify by voice on the owner's iPhone: every phrase, in CarPlay with the
  phone locked, after a force-quit, and that "Play Overplay" reaches
  Overplay rather than an Apple Music search.
- Decide whether the app and CarPlay should offer Undo too.

Fuller voice management (Restore, Play Album, Play Artist) comes after v1.

### 3.2 Rework search

Owner report, 2026-10-18: search is rudimentary, and its UI does not really
work on iPhone.

What it does today (`SearchMusicView`, `SearchMusicViewModel`,
`SearchService`):

- iPhone reaches it only from the menu on a playlist screen (One True
  Playlist, the Inbox or Retired), not from the dashboard. iPad has a sidebar
  entry, and the Mac has Go → Search (⌘F).
- It searches the Apple Music catalogue only, for songs only, returns 20
  results, and runs only when the search is submitted.
- A result cannot be played or previewed, and shows no sign of whether the
  song is already in the One True Playlist, the Inbox or Retired.
- Its only action is adding to a playlist through a MusicKit write. The Inbox is
  never a destination, adding fails on the Mac and on playlists Overplay did
  not create, and a destination picker sits at the top of every search.

Done on 2026-10-19: the field is the whole top bar on iPhone, with X to go
back, and no destination picker; the dashboard has a Search button top right;
results are track rows that swipe right to Overplay and left to the Inbox through
the shared song action, with More beside the Inbox for Play Now (one song,
outside any playlist) and Add to Playlist… (any library playlist but the One
True Playlist). The shared song action, Play Now and Add to Playlist have
tests; the old destination code is gone. Still to do: items 2, 3, a clearer
item 4 and the Mac part of 7 below.

Direction:

1. Start with a pass on the owner's iPhone that lists what breaks, before
   changing layout.
2. Search as you type, debounced, with suggestions
   (`MusicCatalogSearchSuggestionsRequest`).
3. Combine library results (`MusicLibrarySearchRequest`) with catalogue
   results, so library-only songs are found too, and include albums and
   artists. Albums and artists open the existing Library and deep-dive views
   rather than new ones.
4. Show each song's place in Overplay: One True Playlist, the Inbox, Retired or
   untracked.
5. Make **Add to the Inbox** the primary action for an untracked song, and
   **Add to One True Playlist** the secondary one. Use the same shared actions
   as untracked songs in Play Album, Play Artist and Library (`PLAY-018`),
   which go through the shared manual Inbox intake boundary and need no
   playlist write. Drop the destination picker.
6. Playing a result goes through the shared collection start, never a separate
   playback path.
7. iPhone-first layout, with regular width and the Mac following. On the Mac,
   keyboard focus and Return to add.

Update the spec's **Search** screen, **Search and manual add** and `MUT-002`
to match, and add view-model and use-case tests for each action.

### 3.3 Beta settings

- Add a direct action to open system Settings when Apple Music permission is
  denied.
- Clarify the difference between resetting statistics and deleting shared
  local and iCloud data.
- Add a reset-local-playback-state control only if testers need one.
- Observe `MusicSubscription.subscriptionUpdates`, so a subscription or Sync
  Library change updates readiness without a relaunch.

## Milestone 4: External TestFlight and App Store

- Tester notes: what Overplay is, the Apple Music subscription and Sync
  Library requirements, how to share the activity log after a stall, and the
  data decision from 1.4.
- App Store Connect: privacy policy URL, support URL, privacy nutrition labels
  (matching 1.2), age rating, screenshots for iPhone, iPad and the Mac, and
  review notes explaining that an Apple Music subscription is required and
  how CarPlay is reached.
- Decide whether the Mac Catalyst build ships in v1 or stays a TestFlight-only
  platform. Its missing playlist writes must read as intended in review.
- Consider MusicKit's native subscription offer for non-subscribers, if they
  are part of the audience.

## After v1

In rough priority order.

### Fuller Siri

Restore, Play Album, Play Artist and Recent Deep Dives by voice, on the same
shared actions (spec: **Play Album and Play Artist → Surfaces**).

### Mac Helper

Build the menu bar helper in **Mac Helper — Planned** (`HELPER-001`–`HELPER-011`).

1. Close the spec's open checks with throwaway scripts: song IDs in
   `Library.musicdb`, script adds of playlist-only songs, and iCloud
   propagation of script edits.
2. Read-only first: the target, the CloudKit zone, `HelperStatus`, library
   facts, playlist snapshots, backups and stamp history, and the Settings →
   Mac Helper screen.
3. Fast Inbox intake.
4. The One True Playlist writer, starting in plan-only mode.
5. Source cleanup (default off), after the writer has run cleanly for a while.

Verification:

- Unit tests cover desired-state merging, the reconcile plan (removals only
  for suppressed songs, no guessing, collapse, approval thresholds) and the
  iPhone/iPad changes while the writer is on.
- Source cleanup tests cover: restores only from the helper's own removal
  log, skipped sources that cannot be edited, no fighting a source that
  re-adds a song, and putting songs back when the option is turned off or a
  source is unlinked.
- On the owner's Mac and iPhone: a retirement on iPhone leaves Apple Music's
  playlist after the Mac wakes; a promotion appears; a stale device cannot add
  a retired song back; nothing changes in playback. With source cleanup on, a
  retired TikTok song leaves TikTok Songs, and moving it to the Inbox puts it back.

### Expand the Dashboard Summary

- Add recently promoted counts.
- Surface useful Inbox queues such as unreviewed or high-skip items.
- Add direct play, sync, search and history actions where they shorten an
  existing workflow.

### Refine iPad and Mac

The iPad matches the open iPhone Duo layout and is single-window. The Mac
Catalyst build has menus, shortcuts, a Settings window and a title-bar mini
player.

- iPad: hardware-keyboard and pointer interactions beyond Next and Previous.
- Mac: context menus for Promote, Retire and Restore, and table-style History
  and playlist lists where they help scanning.
- Native Mac target: the long-term goal, shelved. It shares models,
  repositories, services and reusable views, starts with management and
  read-only sync, and keeps platform media APIs behind adapters. The Mac
  helper comes first.

### Move Sync Persistence off the Main Actor Only if Profiling Requires It

Playlist sync runs on the MainActor against the main `ModelContext`, with yield
chunking, once-per-cycle identity merge, a shared library-playlist fetch and
inter-playlist pacing. If on-device catch-up sync still hitches:

- Move persistence work to a `@ModelActor` background context.
- Add ID-based re-fetch APIs at live `@Model` boundaries.
- Keep MusicKit fetches behind sendable snapshot boundaries.
- Preserve immediate shared playback-state updates after persistence writes
  that affect current playback UI.

Do not undertake this refactor without profiling evidence.

### Open Enhancements

- #42: album-version replacement for Inbox tracks.
- #56: a playback Live Activity with Promote and Archive actions.
- #73: save a playlist's collage to Photos.

### Consider CarPlay Skip-History Browsing

Only if it fits safely within CarPlay templates and does not make the primary
playlists → tracks → Now Playing flow harder to use. CarPlay browsing stays
focused on Active playlists; Retired content appears only when it is the
current playback context started elsewhere.

## Unscheduled Music Platform Enhancements

These are candidates, not commitments. Promote one to a scoped issue only when
its product benefit justifies its interaction with the shared playback,
persistence and cross-surface invariants above.

### Discovery and Intake

The shared manual Inbox intake boundary already tracks explicit keep intent
independently of contributing playlists. Future intake UI must use it; do not
invent a fake playlist or bypass the global ownership/retention rules.

- Read the user's synced Shazam discoveries from `SHLibrary` and feed them
  directly into the Inbox, retaining Apple Music ID, ISRC, artwork, and
  discovery date where available. Consider in-app Shazam recognition only if it
  adds value beyond the system Music Recognition control.
- Build a discovery inbox from MusicKit personal recommendations, recently
  played content, or Apple Music Replay summaries. Treat these as suggestions
  only: recently played results do not prove completion or identify the source
  playlist and must never directly change Overplay statistics.
- Explore song stations, artist relationships, catalog charts, genres, and
  record-label relationships as optional ways to find candidates related to a
  track the user kept or promoted.
- Consider syncing Apple Music favorites or positive/negative ratings only as
  an explicit opt-in. Promotion and retirement are Overplay concepts and should
  not silently change the user's Apple Music taste profile.

### Library Browsing

- Offer an offline-focused view or playback filter based on MusicKit's
  `includeOnlyDownloadedContent` support if device testing shows that it maps
  cleanly to Overplay's linked playlists.
- Consider MusicKit's system music picker after it leaves beta and demonstrates
  a clear advantage over Overplay's purpose-built selection flows.

### System Surfaces

System Now Playing and remote commands belong to `ApplicationMusicPlayer`'s
host (`PLAY-016`). Ideas that need Overplay to publish Now Playing metadata or
register remote commands (ISRC publication for Music Haptics, like/dislike
commands as Promote/Retire, extra Now Playing identifiers) are withdrawn with
History H-7. Promote, Retire and Restore away from the phone come from CarPlay
templates and Siri.

- Support Music Haptics only if it works without Overplay-authored Now
  Playing, for example if the player host already publishes the ISRC.
- Lock Screen and Control Center scrubbing are the player host's. Define
  seek-aware session accounting so a scrub never manufactures a playthrough or
  hides a witnessed skip (see the same-entry replay item in the spec's Known
  Defects).

### Playback Experience

- Offer MusicKit crossfade as an opt-in playback setting after testing its
  effect on current-entry transitions, elapsed-time accounting, queue-end
  behavior, and cross-surface state.
- Consider a rapid audition mode using queue-entry `startTime` and `endTime`
  windows for the Inbox. It needs distinct statistics semantics because a planned
  short window is neither a normal skip nor a full playthrough.
- If the minimum OS rises to iOS 26.4 or later, consider setting
  `queue.affectsListeningHistory` to false for clearly labeled audition or
  retired-review sessions. Do not disable it for normal playback without
  replacing the Apple Music play-count evidence used by suspended-playback
  reconciliation.
- Surface the active `MusicPlayer.State.audioVariant` or catalog audio variants
  as restrained Lossless, Hi-Res Lossless, or Dolby Atmos badges, following
  Apple's badge guidance and showing the actual active format where possible.

### Reactive Library State

- Use `MPMediaLibraryDidChangeNotification` as a debounced invalidation hint for
  MusicKit playlist caches and linked-playlist sync. Retain periodic sync because
  the notification does not describe the changed resources or guarantee remote
  delivery timing.
