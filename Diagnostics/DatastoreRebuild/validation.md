# Generation-2 cutover validation — 27 September 2026

Implemented specification: `OVERPLAY_DESIGN_SPEC.md`, “Persisted Data Model” and
“Datastore generation 2: configuration-preserving rebuild”.

## Live configuration and import

The configuration-only export was read from the legacy store in read-only mode,
checked again against that store before installation, and preserved these links:

| Playlist | Role | Source song occurrences |
| --- | --- | ---: |
| Overplay | One True Playlist | 102 |
| Favourite Songs | Triage source | 37 |
| My Shazam Tracks | Triage source | 48 |
| Seen | Triage source | 44 |
| TikTok Songs | Triage source | 92 |

All five existing write policies were preserved. No Apple Music playlist mutation
was performed by the cutover. The legacy store remains in place.

323 source occurrences became 294 tracks and 294 memberships:

- Overplay: 101 tracks.
- Triage: 193 tracks.
- Retired: 0 tracks at cutover.
- 24 tracks have occurrence evidence from more than one configured source.
- No duplicate catalog-ID groups, library-ID groups, or membership track-ID groups.
- All 294 primary library references are canonical library resource IDs; 255
  also have a documented catalog resource.
- No native `musicKit:` artwork URLs were persisted.
- Initial skips, Overplay playthroughs, and credited Apple-count totals were zero.

The completed rebuild receipt was verified in the new store. After validation,
the exact configuration export was archived to the application sandbox's
`Documents/overplay-library-rebuild-v2.completed.json`. The pending input was
renamed, not deleted. This prevents a later intentional reset from replaying the
old cutover. The app uses `Application Support/OverplayLibraryV2.store`; the old
`Application Support/default.store` was not modified by the reset.

## Live behavior

On My Mac (Designed for iPad), authorization and library access succeeded. The
replacement imported all configured sources, opened the Overplay screen without
the earlier unresponsiveness, survived restart without another rebuild, and
retained the 101/193 collection counts. A selected song (Phoebe) played after
restart, proving the missing process-local playback material was reconstructed;
Pause worked and the paused display survived another restart.

A manual Overplay sync fetched 102 occurrences, inserted zero tracks, and kept
101 memberships. It exposed one alternating library-resource representative for
Boys (That I Dated In High School): two library IDs prove the same catalog song.
The final implementation chooses a deterministic representative and keeps both
bindings. A regression test imports both orders repeatedly, verifies unchanged
UUIDs/metadata, and asserts the SwiftData context stays clean. The equivalent
merge policy is covered for independently created duplicate records.

That test also exposed same-value identity assignments marking SwiftData dirty
although the repository reported “unchanged”. Identity enrichment now checks
before assigning. This addresses unnecessary shared-state publication rather
than suppressing its visible symptoms.

The first live import exposed literal `{w}`/`{h}` artwork URLs reaching the
network. The download boundary now expands them to a 512px master URL. The live
restart then produced successful downloads/cache writes instead of those 404s.

Final read-only verification after the last build still showed 294 tracks,
294 memberships, 101 Overplay, 193 Triage, and zero duplicate memberships. The app
was left under the user's control; further UI automation stopped when the user
was interacting with it.

## Automated/build evidence

Final full suite: **845 tests in 104 suites passed**, 21.499 seconds.

```sh
rtk proxy xcodebuild test -project Overplay.xcodeproj -scheme Overplay \
  -destination 'platform=iOS Simulator,id=CCF5BAF3-24B4-4B76-8729-12FDA27F5465' \
  -derivedDataPath /private/tmp/overplay-stability-simulator \
  -parallel-testing-enabled NO
```

Log: `/private/tmp/overplay-v2-verified-tests.log`.
The final signed My Mac (Designed for iPad) build succeeded in Xcode and launched.
The earlier signed command-line build log is
`/private/tmp/overplay-v2-mac-build.log`.

Coverage includes atomic rebuild failure/retry, input-order-independent ownership,
restart idempotence, rejection of populated replacement stores, resource domain
and library scope collisions, native cache exclusion and failed reconstruction,
no-op metadata publication, canonical playlist pagination, refusal to relink by
name, template artwork requests, and existing playback/CarPlay behavior.

Physical CarPlay, background behavior on iPhone/iPad, and live convergence between
two devices remain unverified. Simulator unit tests are not evidence for those.
Older builds continue to use the old dataset; other devices need the replacement
build. Production CloudKit schema deployment remains a release step.

Changes remain uncommitted on `codex/carplay-stability`, alongside the earlier
CarPlay and identity work from this task. No commit, push, or PR was created.


## Second-device startup protection — 27 September 2026

Implemented a shared, read-only restoration gate before startup writers run.
An empty V2 store no longer causes automatic settings/bucket creation. CarPlay,
background reconciliation, remote command activation and collage maintenance
use the same readiness boundary. A successful import for the correct local
store plus configuration/reference checks allows restoration; the originating
Mac can use its archived cutover configuration. Subsequent launches use a
local settings-ID receipt and still validate the graph.

Regression coverage includes failed/empty cloud imports, settings arriving
before playlists, memberships arriving before their tracks/source playlists,
offline restart, preference-only restore into an empty database, explicit local
cutover, late cloud delivery racing first-time setup, single service startup
on retry, cancellation on authorization loss, and offline restart after an
explicit database reset. Reset now creates its base triage bucket and records
that the new settings were deliberately created on this device.

- Full suite: **854 tests in 105 suites passed**, 13.779 seconds, on the final tree.
  Log: `/private/tmp/overplay-restoration-final-full.log`.
- Command: `rtk proxy xcodebuild test -project Overplay.xcodeproj -scheme Overplay
  -destination 'platform=iOS Simulator,id=CCF5BAF3-24B4-4B76-8729-12FDA27F5465'
  -derivedDataPath /private/tmp/overplay-stability-simulator -parallel-testing-enabled NO`.
- Signed My Mac (Designed for iPad) build launched successfully with the gate.
  Existing Overplay/Triage/Retired navigation and track list were visible.
  Authorization and live MusicKit library requests succeeded in the startup log.
- Read-only live database check after launch: one settings record, six playlist
  records, 294 tracks and 294 memberships. No additional live reset/reimport.
- Playback interaction was interrupted by user activity; no new playback-result
  claim is made for this turn.
- Physical iPhone and both iPads were reported unavailable by `devicectl` twice.
  Cross-device CloudKit delivery and physical CarPlay remain **unverified**.
- CloudKit Console redirected to Apple sign-in. Production schema and remote
  record availability could not be inspected, and no deployment was performed.
  The running app has the expected `iCloud.farm.poplar.overplay` entitlement;
  its signed entitlements do not explicitly label an environment. Do not infer
  that TestFlight sees this development library. Schema deployment does not
  transfer private data between environments.

CloudKit does not publish the complete graph atomically. These checks establish
configuration readiness and validate references already delivered; they do not
claim that every remote record has arrived. Later records continue to sync.
Empty-account setup is an explicit user action, unavailable with a legacy store;
it is not a distributed lock against simultaneous deliberate setup on two devices.
The work remains uncommitted alongside the earlier datastore/stability changes.

- Final signed Mac compilation succeeded with all restoration/reset changes:
  `/private/tmp/overplay-restoration-mac-build.log`.
- An additional simulator test launch stalled before tests began; its runner
  was interrupted and the simulator was booted again without erasing data.


## Artwork regression — 27 September 2026

The rebuild/import resolver discarded the library song resource after reading
its catalog relationship, losing library artwork whenever no catalog match
existed. It now retains both the library resource and its typed catalog
relationship; library artwork remains independent of catalog identity.
Apple documents artwork on the library resource itself:
https://developer.apple.com/documentation/applemusicapi/librarysongs/attributes-data.dictionary

The player preferred raw MusicKit presentation metadata (including device-only
artwork URLs), while the list and theme used stored portable artwork. Shared
now-playing display now uses stored portable artwork for an exactly matching
current song, retaining player-reported track identity and never borrowing the
outgoing song's cover for a different incoming song. Theme and image read this
same display projection. A background metadata refresh fills missing artwork
without changing track identity, memberships or listening counts, even when
playlist contents have not changed.

Live verification on My Mac (Designed for iPad):
- Missing artwork references fell from 39 to 1 after the automatic refresh.
- The Hand regained its Apple-hosted library artwork URL.
- u + me = <3 was played and its expanded player visually showed the correct
  cover and matching theme. Playback was then paused.
- The remaining track is Bigger Boys And Stolen Sweethearts; the user confirmed
  it is an MP3 upload for which they never supplied artwork. Missing art is
  therefore expected for this track.
- Full regression suite passed: 858 tests. Log:
  `/private/tmp/overplay-artwork-full.log`.
- Focused import/repair/shared-player tests passed. Log:
  `/private/tmp/overplay-artwork-focused.log`.
- The signed Mac app built and launched through Xcode. Physical iPhone and
  CarPlay were not separately exercised for this artwork change.
