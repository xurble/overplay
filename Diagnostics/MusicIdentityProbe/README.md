# MusicKit identity investigation — 27 September 2026

The song's origin is not the cause. A catalog song and a matched/uploaded song
both reproduce the identifier mismatch. This is Overplay confusing identifiers
returned by different MusicKit requests.

## Reproduction

Run `rtk proxy python3 Diagnostics/MusicIdentityProbe/prepare.py`, open the printed
project in Xcode, select **Overplay → My Mac (Designed for iPad)**, and Run.
The project contains only the probe and the production `MusicLibrarySongResolver`.
It does not include SwiftData, AppRuntime, a player, automatic sync, remote commands,
or library mutation code. It makes read-only MusicKit requests and saves one report
to `Documents/music-identity-probe.txt` in the app container.

It uses the existing configured app identifier and signing profile to test the
same MusicKit authorization. It is a separate executable/project, **not a separate
app container**. Xcode can replace the debug installation. Never add ordinary
Overplay startup code to this harness. Return to the normal project for subsequent
app development. Local signing configuration is copied only to the temporary
directory, not to this diagnostic folder.

## Observed evidence

See `observed-responses.txt` for the sanitized live response report. No credentials
or authorization headers are recorded. Environment: macOS 26.5, Designed for iPad,
existing Apple Music authorization granted.

| Song | Playlist-entry song ID | Direct library request returns | Catalog relationship |
| --- | --- | --- | --- |
| Archie, Marry Me | `-3140821922437280474` | `i.O1RQbZGuVYYl7v` | `878984806` |
| All Nighter | `-2540034726386153049` | `i.1YBNxGGsqAAPdr` | Explicitly empty |
| California Stars | `7155078121927443764` | `i.1YBNkWOHqAAPdr` | `925214201` |

Every numeric ID queried directly through `/v1/me/library/songs?ids=…&include=catalog`
returned `{"data":[]}`. The corresponding direct `MusicLibraryRequest<Song>` lookup
returned the existing `i.…` ID; the web library endpoint then returned that resource
and its catalog relationship. This establishes equivalence through API responses,
not through song titles, album names, durations, or assumptions about CD imports.
It does not establish the numeric identifiers' portability across devices.

The actual new resolver resolved all **102 song occurrences** in the Overplay
playlist, representing **101 distinct library songs**, with zero failures in
about **0.19 seconds**. All 101 returned library IDs were subsequently verified
against the web library endpoint, including explicit catalog relationships.

The [library request API](https://developer.apple.com/documentation/musickit/musiclibraryrequest)
and [web library-song endpoint](https://developer.apple.com/documentation/applemusicapi/get-multiple-library-songs)
are separate request boundaries. MusicKit's `MusicItemID` type alone does not make
the identifiers interchangeable between them.

## Confirmed duplication chain and change

1. Playlist entries provided native numeric song IDs.
2. `MusicTrackIdentity` guessed domain from syntax and opaque playback parameters.
3. `MusicIdentityResolver` sent the numeric library IDs directly to the web API.
4. Its decoder prepopulated an empty result for every requested ID, conflating
   **missing resource** with **returned library song with no catalog match**.
5. Enrichment marked the identity documented. Its caller also swallowed failures
   and continued importing raw snapshots.
6. Repository matching found neither the existing library ID nor catalog ID and
   created another track and playlist membership. Existing membership is deliberately
   retained when absent from remote sync, so the original remained as well.

Normal playlist sync and playlist copying now resolve observed songs through the
same `MusicLibrarySongResolver` boundary before creating persistent snapshots.
The request determines library versus catalog identity; ID syntax and serialized
play parameters do not choose persistent import identity. A catalog-only playlist
song can resolve through an explicit catalog request when no library song exists.
Missing or ambiguous resolution aborts the fetch before reconciliation. Native
mappings are operation-local and are not added to shared identity aliases.

The web decoder now requires the library resource itself to be present. A returned
library resource with an explicitly empty catalog relationship remains valid.
Enrichment failure no longer falls through to raw-ID import. Playlist copying
resolves identity before remote creation and before changing local playlist roles.
Import does not request optional ISRC/equivalent-song suggestions: failure of a
duplicate-review lookup must not block an otherwise verified library identity.

Regression fixtures exercise the actual source adapter and sync service with an
in-memory store: repeated import preserves existing UUIDs, memberships and play/skip
counts, including the song without a catalog match; a failure after an earlier
successful resolution writes no partial track import. Tests also cover web misses,
explicit API domains, and repeated occurrences.

## Remaining work, deliberately separate

### Existing duplicate repair

Use the verified native-to-library mappings to build an explicit donor/keeper
report. Feed only proven mappings into the shared merge operation, preserving
history, retirement, source provenance, playback references and counter baselines.
Do not merge on title or add play-count baselines twice. Validate against a disposable
store snapshot first. No existing tracks, playlists, or history were repaired here.

### Playlist identity

The playlist enumeration returned a numeric ID and querying that same ID directly
still returned the numeric ID. The song mapping cannot simply be applied to playlists.
Next probe the web library's playlist IDs through native filtered requests, correlating
only explicit API results. Persist a verified account library reference and retain
any native lookup handle locally. Replace name-based healing only once that mapping
is demonstrated; two playlists with the same name must stay distinct.

### Artwork and the unresponsive playlist

Both entry songs and directly resolved songs return `musicKit:` artwork URLs on
this destination. Resolving song identity alone does not turn these into HTTP URLs.
The supplied log contains hundreds of zero-byte artwork downloads and decode failures.
The cache currently downloads URL templates through URLSession. The fundamental
boundary should distinguish a native MusicKit artwork resource from a web image
resource, resolve each through its supported provider, and publish only changed
image state. Persist portable artwork metadata and keep native handles device-local.
Treat unavailable artwork as stable state until its source/version changes.

This is evidence of wasted work, not yet proof of the exact main-thread freeze.
The everyday app was already stopped; it was not restarted with auto-sync to obtain
a misleading sample. Reproduce from a disposable store snapshot with sync disabled,
sample while unresponsive, and trace the stack through presentation rebuilds,
SwiftData fetches and artwork delivery before changing those paths. Require bounded
work and unchanged presentation output across idle/save/artwork events.

### Shared model hardening

Keep Overplay UUIDs as the owners of history and membership. Make external references
carry an explicit domain and account scope; keep native queue/playback/artwork handles
out of shared identity. Require verified identity at each durable intake boundary
(including catalog search and future providers), and represent unresolved resources
explicitly rather than treating absence as a new song. Audit playback correlation,
count recovery and merge aliases against those same domains. Do not add a broad
schema migration until these remaining identity contracts are established.

Full app playback, iPhone/iPad cross-device behavior, and CarPlay flicker remain
separate live checks. The read-only probe proves library identity resolution, not
playback readiness or UI responsiveness.

## Validation

- Final complete simulator unit suite: **832 tests in 103 suites passed**. This
  validates injected logic and in-memory persistence, not live MusicKit playback.
- Final **My Mac (Designed for iPad)** app build and signing succeeded.
- Live read-only resolver run: 102 occurrences, 101 distinct verified web library
  resources, no unresolved songs. No everyday SwiftData store was opened by the probe.
- The temporary probe was stopped and Xcode returned to the ordinary project;
  ordinary app startup/automatic sync was not run against the everyday store.

Build/test logs for this run are `/private/tmp/overplay-identity-verified-build.log`
and `/private/tmp/overplay-identity-verified-tests.log`.
