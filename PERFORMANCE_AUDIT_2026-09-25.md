# Performance improvement hit-list


Implementation follow-up: [changes, instrumentation and investigation guide](PERFORMANCE_IMPLEMENTATION_2026-09-25.md). This audit preserves the original baseline findings.

Audit date: 25 September 2026. Code baseline: `22a78cb`.

The clearest immediate improvements are to let cached artwork appear during scrolling, eliminate repeated main-actor Apple play-count queries, coalesce count refreshes, and remove account/storefront resolution from the critical path for starting a locally cached queue.

This is a source-code investigation, not a device profile. The mechanisms below are present in the code; their contribution to measured frame hitches, network traffic, and time to audible playback still needs timing on a physical device. No application code was changed. No build or test suite was run for this documentation-only audit.

Artwork direction from the follow-up discussion: use exactly two real representations, **128×128 for rows/mini player and 512×512 for recognition/expanded player**, with the cached 128 shown immediately while 512 loads. The recommendation below is to persist thumbnails broadly and keep only a small, bounded cache of recently used 512 images. Memory-only retention of 512 is a viable alternative; that retention choice remains a recommendation, not an implemented change.

## What best explains the observations

| Observation | Strongest code-backed explanation | Qualification |
| --- | --- | --- |
| Blank artwork while fast scrolling, followed by pop-in | Scrolling disables the entire artwork loader, including its memory-cache lookup. Work restarts when scrolling stops. | Direct behavior, not just a hypothesis. Existing images remain, but newly encountered rows cannot acquire one. |
| Scrolling stutters | Count getters perform synchronous SwiftData queries; refreshes repeatedly reconstruct count history and rebuild playlist snapshots on the main actor. Artwork/task bursts and full-list identity-string generation add work. | Strong candidates. A Time Profiler/SwiftUI trace is needed to rank their actual costs. |
| Playback takes time to start | A replacement queue decodes all its stored MusicKit tracks, awaits token/storefront scope, reconciles player state, materializes the full queue, then calls Play. | These are serial dependencies before or during startup. MusicKit delivery latency is separate. |
| Next/Previous are fast, selecting a particular track is slow | Next/Previous use native skip commands. In-queue selection locates an entry, assigns `currentEntry`, and awaits `play()`; a selection outside the matching live queue uses the full replacement path. | The latest commit already shares in-queue selection between app and CarPlay. It would be incorrect to say every row tap rebuilds the queue. |
| API use seems too aggressive | A new immediate/60-second count loop queries all retained IDs; fallback count lookup can additionally page whole playlists. Foreground and post-sync calls have no bulk freshness gate. | MusicKit requests are not necessarily one-for-one remote HTTP requests: the framework may serve/cache some locally. Count both calls and actual transfer where available. |

Recent regression candidates are `49c776d` (Apple counts and database-backed getters), `dd2930c` (whole-playlist/recent-history count fallbacks), and `eb2eb35` (scope checks and richer queue correlation), all dated 25 September. Artwork loading issues predate these changes. Temporal proximity identifies profiling candidates; it does not prove causation. `22a78cb` already fixes a previous app/CarPlay row-selection divergence and should be preserved.

## Prioritized list

P1 means investigate/implement first; P2 means the next wave or dependent on profiling. Effort is relative: S = local change, M = coordinated change across a few types, L = persistence/concurrency work with substantial regression coverage.

| ID | Priority | Improvement | Main benefit | Effort |
| --- | --- | --- | --- | --- |
| PA-01 | P1 | Permit cached artwork during scrolling; prefetch a small nearby window | Removes avoidable blank rows and end-of-scroll bursts | M |
| PA-02 | P1 | Use real 128/512 variants with thumbnail-first expanded artwork | Less duplicate disk data and oversized decoding; immediate artwork | M |
| PA-03 | P1 | Share decoded artwork across playlists; use a byte budget and coalesce decoding | Less memory pressure and repeated decode work | M |
| PA-04 | P1 | Bound and prioritize artwork work | Visible rows stop competing equally with background warmup | M |
| PA-05 | P1 | Batch/materialize Apple count reads instead of querying from getters | Removes database work from UI and playback hot paths | L |
| PA-06 | P1 | Coalesce count refresh triggers and whole-playlist fallbacks | Fewer repeated MusicKit calls and database passes | M |
| PA-07 | P1 | Publish count changes only when presentation actually changed | Avoids full playlist/CarPlay/history refreshes on no-op work | M |
| PA-08 | P1 | Decouple account/storefront verification from queue startup | Removes avoidable pre-Play waits | M |
| PA-09 | P1 | Reuse queue preparation and measure row-selection stages separately | Faster cold selection; identifies MusicKit versus app delay | M |
| PA-10 | P2 | Make ordinary playback ticks cheap | Less recurring main-actor work during scrolling | M |
| PA-11 | P2 | Batch queue-association validation and persistence | Faster queue re-correlation after hydration/shuffle | M |
| PA-12 | P2 | Defer theme/OCR warmup and batch its store writes | Less CPU, image traffic, and disk amplification after sync | M |
| PA-13 | P2 | Stop repeatedly decoding the whole library for video cleanup | Faster startup and playlist sync | M |
| PA-14 | P2 | Index count-discovery candidates once | Faster unresolved-track discovery | M |
| PA-15 | P2 | Replace full-list string keys with scoped revisions | Less work when scroll state/current row changes | M |
| PA-16 | P2 | Correct artwork access accounting and eviction protection | Fewer avoidable cache misses after sustained use | S–M |

## Artwork and scrolling

### PA-01 — Allow cached images to appear while scrolling

**Evidence:** [PlaylistManagementView.swift:152](/Users/g/Code/overplay/Overplay/Views/PlaylistManagementView.swift:152), [row construction:293](/Users/g/Code/overplay/Overplay/Views/PlaylistManagementView.swift:293), [ArtworkView.swift:119](/Users/g/Code/overplay/Overplay/Views/Components/ArtworkView.swift:119).

`isScrolling` becomes `loadsArtworkImmediately: !isScrolling`. `loadArtwork()` immediately returns when that flag is false, before asking the decoded-image cache. The flag is also part of `.task(id:)`, so scroll-phase changes cancel/restart row loading. A disk-warm or memory-warm row can therefore show a placeholder during the entire scroll. Stopping the scroll releases the waiting rows together.

**Change:** separate permission to display cached content from permission to begin expensive work. Always make a ready decoded image available. Allow bounded local thumbnail loads during scrolling. Limit new downloads and speculative work according to visibility and velocity. Prefetch roughly one or two screens ahead in the current scroll direction, with a small bounded window rather than the whole playlist. Seed the initial visible window when entering a playlist. The existing playback prefetch loads only current-track artwork; theme warmup does not prepare decoded row thumbnails.

**Verify:** warm-memory, warm-disk, and cold-cache scrolls separately. Revisiting a decoded row should not wait for scroll idle. Count placeholder frames, image-ready latency, active requests and decodes, and end-of-scroll frame hitches. Cold network misses can still show a placeholder; they should not block rows whose images are ready.

### PA-02 — Use real 128/512 variants and upgrade expanded artwork progressively

**Evidence:** [ArtworkCacheService.swift:48](/Users/g/Code/overplay/Overplay/Services/ArtworkCacheService.swift:48), [download path:92](/Users/g/Code/overplay/Overplay/Services/ArtworkCacheService.swift:92), [raw write:345](/Users/g/Code/overplay/Overplay/Services/ArtworkCacheService.swift:345), [source snapshots:295](/Users/g/Code/overplay/Overplay/Services/AppleMusicPlaylistSourceSync.swift:295), [NowPlayingArtworkView:4](/Users/g/Code/overplay/Overplay/Views/NowPlaying/NowPlayingComponents.swift:4).

The cache includes `pixelSize` in the key but downloads the supplied URL unchanged and writes the returned bytes unchanged. Most synced artwork URLs are already concrete 512×512 requests. Asking for 96, 128, 144, and 512 therefore creates separate cache entries for the same source resource; it does not create four correctly sized files. Concurrent requests at different sizes also use different in-flight download keys. URLSession/CDN caching may avoid some repeated transfer, but Overplay's own files still duplicate the resource.

The view already uses ImageIO thumbnail decoding off the main actor. Keep that: the row's *decoded* bitmap is bounded to 144 pixels. The missing optimization is the source/disk representation and the choice of dimensions at each call site, not adding the first downsampler.

Current dimensions and the native-resolution reference (the proposed two-size policy deliberately trades some sharpness for simplicity):

| Consumer | Current request/decode cap | Actual display or processing requirement |
| --- | --- | --- |
| Playlist/history/search row | 144 pixels; usually a 512-pixel playlist source, 160-pixel search source | 72 points → 144 pixels at 2×, 216 at 3× |
| Home/picker artwork | 96 pixels | 48 points → 96 pixels at 2×, 144 at 3× |
| Mini player | Defaults to 512 pixels | 50 points → 100 pixels at 2×, 150 at 3× |
| Current expanded player pane | Defaults to 512 pixels | Layout caps art at 260 points → up to 520 pixels at 2×, 780 at 3× |
| Theme palette | Cache key says 128 pixels | Builder actually downsamples to 100 pixels |
| Theme text recognition | Uses that same nominal 128 cache entry | Builder separately downsamples to **512 pixels** for OCR |

Display evidence: [72-point row](/Users/g/Code/overplay/Overplay/Views/Components/PlaylistTrackRowView.swift:12), [48-point home row](/Users/g/Code/overplay/Overplay/Views/Components/PlaylistHomeRowView.swift:14), [50-point mini player](/Users/g/Code/overplay/Overplay/Views/NowPlaying/MiniPlayerLozengeView.swift:32), [expanded layout](/Users/g/Code/overplay/Overplay/Views/NowPlaying/NowPlayingPaneView.swift:21), [palette and OCR sizes](/Users/g/Code/overplay/Overplay/Presentation/AlbumArtworkTheme.swift:388).

**Change:** use exactly two actual sizes:

- **128×128:** persist on disk for rows and the mini player, backed by a shared decoded-memory cache. Reuse the same thumbnail across playlists, history, search and player surfaces. The thumbnail must remain available during scrolling.
- **512×512:** request for recognition and the expanded player. Share one in-flight download between these consumers. Recommend a small, separate disk budget for recently used images, retaining the current image in memory. Avoid retaining a decoded 512 image for every track. Persist the recognition/theme result separately so repeat visits do not rerun OCR.

Expanded-player loading sequence: display an already-ready 512 if available; otherwise show the cached 128 immediately. Asynchronously obtain and decode 512, then replace the thumbnail without changing layout or passing through a blank placeholder. Keep the thumbnail if the larger request fails or the device is offline. A result arriving after the user changes track may enter the cache but must not replace the new track's artwork. All of this runs independently of audio startup.

Preserve a shared asset identity, distinguish source images from derivatives, and generate/cache 128 from an available 512 instead of downloading it again. On a row-only cold miss, obtain 128 directly when source metadata supports a sized request. Request 512 only when needed by the player or recognition; eager whole-library OCR warmup would otherwise defeat this demand-based policy. Use the existing MusicKit-provided artwork metadata/URL, without an additional song or playlist API lookup just to display the larger image.

**512 retention tradeoff:** omitting a persistent 512 cache is workable: keep the current/recent large images in bounded memory, release temporary recognition images, and retain only thumbnails and theme results on disk. However, reopening the app or revisiting an evicted track can require another download, and offline playback will show the thumbnail. A small on-disk LRU of compressed 512 files better supports the original aim of reducing API/network pressure. The existing 250 MB artwork budget need not be filled or enlarged. URLSession's own HTTP cache is separate; memory-only application caching does not itself guarantee that no response bytes are stored on disk.

**Quality tradeoff:** 128 is below native pixel resolution for the current 72-point rows (144 pixels at 2×, 216 at 3×), so it may look softer, especially on 3× screens. The 512 expanded image retains the current resolution but is below the 780 pixels needed for a 260-point image at 3×. These are visual acceptance checks, not reasons to introduce additional sizes now. In a four-byte-per-pixel decoded representation, 128 uses about 64 KiB versus 1 MiB for 512: a 16× difference before overhead. Disk-file sizes depend on compression and image content.

Generate sized URLs through MusicKit's documented [`Artwork.url(width:height:)`](https://developer.apple.com/documentation/musickit/artwork/url%28width%3Aheight%3A%29), retaining enough source metadata to do so. Avoid arbitrary string surgery on concrete CDN URLs. ImageIO downsampling should remain part of decode, consistent with Apple's [image and graphics guidance](https://devstreaming-cdn.apple.com/videos/wwdc/2018/219mybpx95zm9x/219/219_image_and_graphics_best_practices.pdf).

Two details matter before implementing a global cap:

- The nominal 128-pixel theme request currently carries a 512-pixel source that OCR uses. Actually shrinking it to 128 without changing theme processing would reduce OCR quality. Palette and OCR have different useful sizes.
- Search results request 160 pixels, and [manual add persists that URL](/Users/g/Code/overplay/Overplay/Services/PlaylistMutationService.swift:154). [Track upsert only fills missing artwork](/Users/g/Code/overplay/Overplay/Persistence/TrackRecordRepository.swift:176), so later sync can leave the small source in place. Preserve upgradeable artwork metadata and allow a better representation. Upscaling a 160-pixel file is not the solution.

`NowPlayingView` also contains an uncapped artwork layout, but repository references currently show only its own preview. Check the visual adequacy of 512 again if a larger layout becomes live.

**Verify:** use real JPEG/PNG fixtures; inspect actual 128/512 cached dimensions, source request dimensions, transfer bytes, and decoded sizes. Cover thumbnail-first expanded display, failure/offline fallback, a track change during download, shared OCR/player download, repeated album art across playlists, and search-added tracks. Visually check thumbnail softness on 2×/3× screens. Existing [cache tests](/Users/g/Code/overplay/OverplayTests/ArtworkCacheServiceTests.swift:26) mainly cache arbitrary bytes; they do not establish image-sizing correctness.

### PA-03 — Share decoded images and budget by memory cost

**Evidence:** [DecodedArtworkImageCache](/Users/g/Code/overplay/Overplay/Views/Components/ArtworkView.swift:12), [decoded identity](/Users/g/Code/overplay/Overplay/Views/Components/ArtworkView.swift:111), [decode launch](/Users/g/Code/overplay/Overplay/Views/Components/ArtworkView.swift:155).

The decoded key includes `playlistID`, although the same URL/size produces the same bitmap. The same album can therefore be decoded and retained again for another playlist or a playlist-less history row. Concurrent misses also launch independent decodes; only downloading is coalesced. Capacity is 300 images regardless of their pixel cost, with no explicit memory-pressure handling in this cache.

For scale, 300 square 512-pixel images at four bytes per pixel represent about **300 MiB** of pixel storage; 300 square 144-pixel images represent about **24 MiB**. These are illustrative bounds, not measured usage or a claim that the cache always contains 300 large images. The 512-pixel mini-player bitmap has roughly 12 times the pixels needed for 150 pixels.

**Change:** key decoded content by asset identity and actual derivative size; track playlist usage separately. Share an in-flight decode per key. Bound memory by `bytesPerRow × height`, keep recently visible thumbnails preferentially, and respond to memory pressure. A costed cache can retain more thumbnails without keeping hundreds of hero images. Replacing the array-based LRU is secondary: the current linear scan is bounded to 300 and is less concerning than bitmap duplication.

**Verify:** two playlists/history showing the same image should share one decode; measure resident memory and hit rates after a long scroll and repeated player expansion. Test cancellation/reuse so old results cannot land in a row that now represents another asset.

### PA-04 — Bound downloads and decoding; make visible work first

**Evidence:** [download coalescing](/Users/g/Code/overplay/Overplay/Services/ArtworkCacheService.swift:232), [row load](/Users/g/Code/overplay/Overplay/Views/Components/ArtworkView.swift:139), [theme warmup](/Users/g/Code/overplay/Overplay/Services/AlbumArtworkThemeWarmupService.swift:45).

There is no app-level total download limit in `ArtworkCacheService`. Visible cache misses use its default `.background` priority, decodes run `.utility`, and detached decoding is not canceled automatically with the row task. Theme warmup has a two-task limit, but that limit does not cover all visible artwork requests. Task priority alone does not express a complete visible-image/network scheduling policy.

**Change:** use one shared image pipeline with bounded download/decode concurrency, demand tracking and priorities: current/visible image, nearby prefetch, then background themes. Start conservatively (for example four downloads and two decodes) and tune with device evidence. Cancel obsolete queued work and retain useful shared work only while it has demand. Add short failure cooldowns/backoff, honoring retry guidance where supplied, so scrolling past a broken URL does not repeatedly retry it. Promote an existing background job when it becomes visible.

**Verify:** request/decode maxima are enforced under rapid scrolling; visible images make progress during warmup; repeated failures stay bounded; canceling one consumer does not cancel another consumer's shared image.

### PA-16 — Fix cache access accounting and protection

**Evidence:** [read-only disk lookup](/Users/g/Code/overplay/Overplay/Services/ArtworkCacheService.swift:122), [hit path](/Users/g/Code/overplay/Overplay/Views/Components/ArtworkView.swift:140), [eviction](/Users/g/Code/overplay/Overplay/Services/ArtworkCacheService.swift:373), [current-track prefetch](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:3186).

Normal view disk hits use the read-only lookup, bypassing access-time and playlist-association updates. Memory hits also do not update disk usage. Playlist entry touches help playlist-level recency, but do not fully describe individual accesses or a file shared with another playlist. Search/history art can be used repeatedly without its recorded access becoming recent. Protection of the playing playlist is supplied by the current-track prefetch call, rather than being a cache-wide policy; unrelated downloads can run eviction without that protection.

**Change:** batch access/association updates separately from the synchronous image-hit path. Give the cache a shared current-playlist protection policy for every eviction pass. Track total bytes incrementally and prune in batches where useful. The existing manifest writer is already debounced; preserve that behavior.

**Verify:** a frequently revisited history image survives a less-used image; association of an existing file with a second playlist is recorded; a background image download cannot evict protected current-playlist art. Define how protection interacts with the disk budget when the protected set itself is large.

## Play counts, API traffic, and presentation invalidation

### PA-05 — Remove database queries from frequently read count properties

**Evidence:** [PlaylistItemRecord getters](/Users/g/Code/overplay/Overplay/Models/PlaylistItemRecord.swift:35), [count fetch](/Users/g/Code/overplay/Overplay/Persistence/ApplePlayCountRepository.swift:27), [state reconstruction](/Users/g/Code/overplay/Overplay/Persistence/ApplePlayCountRepository.swift:49), [bulk apply](/Users/g/Code/overplay/Overplay/Services/ApplePlayCountSyncService.swift:301).

`applePlayCount` is a SwiftData fetch, not a stored integer read. `applePlayCountState` fetches every observation for the item/merge lineage, decodes JSON, and joins the states. Calling `applePlayCountResetAt` reconstructs that state too.

An unchanged initialized item in `apply` can therefore require two state reconstructions (`resetAt`, then `previous`) plus a count fetch. `refresh` first calls reconciliation with no observations, then persists the fetched observations, repeating the whole-item loop. Discovery and each playlist/recent fallback add further passes. Row and active-snapshot construction also read these properties. All of this service runs on `@MainActor`; a background-priority task does not move synchronous work off that actor.

The record already has an item-ID index. Adding that index again would not fix repeated fetch/decode/join work. Append-only evidence grows when observations change, so reconstruction cost can increase with usage; unchanged counters do not automatically append one new record every minute.

**Change:** batch-fetch evidence for relevant items and their lineage, join once per batch, and provide a value snapshot containing count/state/reset information. UI and playback should consume already-computed count values. Cache by an evidence revision with explicit invalidation for local writes, reset, merge and CloudKit import. Move pure joining/matching onto a suitable non-main executor using Sendable values; keep SwiftData contexts confined to their owner. A separate local projection is an option if an in-memory projection is insufficient. Preserve immutable CloudKit evidence, monotonic floors and reset semantics.

**Verify:** count fetches and state decodes for 100/1,000/5,000 items and increasing evidence history. Building a presentation should not issue one query per row. Re-run Apple count, cloud import, alias merge and reset tests. Test imported evidence from another context; an optimization must not make the display stale.

### PA-06 — Coalesce triggers and control expensive fallback count lookups

**Evidence:** [periodic count loop](/Users/g/Code/overplay/Overplay/Services/PeriodicPlaylistSyncService.swift:57), [foreground refresh](/Users/g/Code/overplay/Overplay/OverplayApp.swift:100), [bulk service](/Users/g/Code/overplay/Overplay/Services/ApplePlayCountSyncService.swift:54), [playlist fallback](/Users/g/Code/overplay/Overplay/Services/ApplePlayCountSyncService.swift:204), [whole-playlist fetch](/Users/g/Code/overplay/Overplay/Services/MusicKitLibraryPlaybackHistoryFetcher.swift:70).

The periodic count task runs immediately, then sleeps 60 seconds after each completed refresh. It does not share the normal playlist sync's ten-second startup delay. Foregrounding and post-sync refreshes can run shortly before or after it. `isRefreshing` prevents overlapping *bulk* calls, but there is no last-success freshness gate, so sequential triggers repeat the same direct-ID work.

Each bulk pass queries distinct retained aliases/counter IDs in batches of 100. An unresolved or alternative-counter track can trigger a complete source-playlist entry load, independent of the 30-minute playlist-content sync policy. This is deliberate count freshness behavior, but potentially much more expensive than the normal sync now is. Already-learned alternative counters remain eligible; this is not only a one-time discovery cost.

The 60-second `playlistResults` cache is populated only after success. It has no per-playlist in-flight task or failed-attempt cooldown. A priority current-track request and the bulk request can both miss it and start the same playlist fetch; failures can be retried by different track lookups. Recent-history lookup does have an attempt timestamp, so it should not be described as unthrottled.

Illustrative request model, not a measurement: 2,000 distinct IDs require 20 direct queries per pass. Four qualifying playlists of 1,000 entries each can add around 40 entry-page loads if pages are 100 entries, plus playlist metadata resolution. Actual first-page sizes/cache behavior are framework-dependent. A full library discovery adds approximately `ceil(library songs / 500)` nonempty requests and a final empty request under the current loop.

**Change:** unify triggers through one freshness-aware scheduler. Share per-playlist in-flight work and failure cooldowns across bulk/priority requests. Reuse complete, timestamped count observations from an immediately preceding sync rather than fetching the same playlist again. Preserve each observation's capture/reset boundary. Match and persist only affected items after a focused lookup. Delay optional startup work until the initial UI/playback interaction has had a chance to complete.

The [design spec:545](/Users/g/Code/overplay/OVERPLAY_DESIGN_SPEC.md:545) explicitly requires retained-track refresh every minute and on foreground/post-sync. Coalescing redundant work can preserve that behavior. Reducing broad refresh frequency, refreshing retired items less often, or backing off permanently unresolved tracks for much longer is a **product-policy change** and should be recorded in the specification, not silently introduced as an optimization. Playlist modification dates cannot establish that play counts are unchanged.

**Verify:** simulate simultaneous foreground, periodic, post-sync and current-track triggers. Assert bounded calls, one in-flight fetch per resource, cooldown after failures, immediate current-track service, and no stale pre-reset observations being replayed as fresh data. Measure calls per operation and returned counts separately from actual network bytes.

### PA-07 — Stop no-op refreshes from rebuilding every surface

**Evidence:** [reconcile](/Users/g/Code/overplay/Overplay/Services/ApplePlayCountSyncService.swift:263), [refresh completion](/Users/g/Code/overplay/Overplay/Services/ApplePlayCountSyncService.swift:91), [refreshPlayCountMetadata](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:305), [snapshot rebuild](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:3851), [CarPlay observers](/Users/g/Code/overplay/Overplay/CarPlaySupport/CarPlayCoordinator.swift:419).

A bulk refresh publishes once from its initial reconciliation and again on completion, even if no counts changed. Publication unconditionally bumps `playbackItemMetadataVersion` and rebuilds the active playlist snapshot, which gets a fresh `updatedAt`. Playlist detail and History use these versions as invalidation inputs. CarPlay listens both to model saves and to snapshot changes, so a logical update can also cause multiple template refreshes.

**Change:** carry changed item IDs and presentation differences out of the count service. Patch affected snapshot rows, and bump the visible revision only when displayed values change. Coalesce CarPlay refreshes by meaningful content/signature. Preserve the existing cross-context adoption behavior: a service can report no local writes while another context has imported new evidence, so checking only `changed > 0` is insufficient.

**Verify:** an unchanged refresh produces no full snapshot rebuild, history reload, or CarPlay template update. A real current/non-current row count change updates all relevant surfaces promptly, including CloudKit and secondary-context changes.

### PA-14 — Index discovery instead of rescanning the library for each track

**Evidence:** [discovery loop](/Users/g/Code/overplay/Overplay/Services/ApplePlayCountSyncService.swift:79), [ApplePlayCountMatcher](/Users/g/Code/overplay/Overplay/Services/ApplePlayCountMatcher.swift:23).

Each unresolved track filters the entire library for aliases, then potentially ISRC and normalized title/artist/album. String folding and set construction repeat across comparisons. For U unresolved tracks and L library entries this is roughly O(U×L) work, with multiple passes possible. `Task.yield()` happens between targets; it does not make one target's long scan cheap.

**Change:** normalize library entries once and build alias, ISRC, and metadata candidate indexes. Keep all candidates, including missing-count entries, to preserve ambiguity checks. Apply duration/ISRC rules only to candidate sets. Reuse a recent complete discovery snapshot for priority lookups when its account/freshness scope is valid, then fall back to the documented focused request.

**Verify:** indexed results equal the current matcher for ambiguous copies, nil counts, duration boundaries and conflicting ISRCs. Benchmark synthetic large libraries with all targets unresolved. Run pure matching away from the main actor.

## Playback startup and specific-track selection

### PA-08 — Remove scope resolution as a mandatory pre-Play dependency

**Evidence:** [startPlayback](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:1011), [refreshAssociationScope](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:438), [liveScope](/Users/g/Code/overplay/Overplay/Services/MusicIdentityResolver.swift:198).

Every replacement queue awaits scope verification before calling Play. Verification serially obtains a developer token, user token, and current country code. The code does not memoize/coalesce this scope lookup at the controller boundary. MusicKit may cache these internally, but an app-controlled latency dependency still exists. The direct live-queue jump does not perform this check, making it a plausible explanation for slower startup/out-of-context selection than Next/Previous.

**Change:** refresh/verify account scope ahead of user commands and share concurrent verification. Most importantly, allow queue submission and trusted current-submission evidence without waiting for persistent association-cache reuse. If scope is unverified, keep persistent associations unavailable while playback proceeds; enable them only after safe verification. Preserve account/storefront isolation and revocation on changes. A stale scope must not permit another account's cached metadata associations.

**Verify:** inject slow/failing scope resolution and prove a playable local queue can receive Play without waiting for it. Confirm account-change isolation, initial queue hydration and restoration behavior. Add timings for scope resolution; the current player-Play timer does not include this wait.

### PA-09 — Reuse queue preparation and separate the two selection paths

**Evidence:** [shared selection](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:627), [in-queue selection](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:660), [cached queue construction](/Users/g/Code/overplay/Overplay/Playback/PlaybackQueueOrchestrator.swift:80), [per-track JSON decode](/Users/g/Code/overplay/Overplay/Playback/PlaybackQueueCoordinator.swift:101), [player entry jump](/Users/g/Code/overplay/Overplay/Playback/PlaybackPlayer.swift:136).

The replacement path fetches membership/tracks and JSON-decodes every playable MusicKit `Track` on the main actor before starting. It then materializes every queue entry and constructs submission metadata. Repeated starts pay this cost again. The complete queue is an intentional requirement for MusicKit shuffle/repeat; removing most of it would change behavior.

For the matching live playlist/scope, the latest code already uses in-place selection. That path refreshes state, finds the target, assigns MusicKit's `currentEntry`, calls `play()`, and confirms the resulting entry. Next/Previous call dedicated skip APIs instead. Whether `currentEntry` assignment/Play is intrinsically slower requires device measurement; it is not evidence of a catalog fetch on every tap.

**Change:** cache prepared track values by playback-data/membership/order revisions, invalidate on actual changes, and reuse queue inputs. Move safe preparation onto an appropriate executor using value data; SwiftData models must not cross actors casually. Keep a generation-scoped live-entry index if queue scans are significant. Record why a selection fell back to replacement (playlist/scope mismatch, target missing, external queue change), and separate native entry selection from the `play()` wait. Avoid speculative changes to resume semantics until timing establishes the expensive boundary.

The confirmation window is up to 20 × 100 ms after the player command returns. It returns immediately when the entry is confirmed; it is **not** an unconditional two-second delay. A timed-out replacement can enter another bounded confirmation loop while restoring the outgoing queue, plus any time spent in MusicKit calls. Label these failure-path timings separately.

**Verify:** cold start, same-queue arbitrary row, same-current row playing/paused, different playlist, Active/Retired scope change, external replacement, shuffled queue, partial hydration and failure recovery. Exercise the shared `playPlaylist(...startingAt:)` action and preserve outgoing accounting, no unwanted restart, and no fragment of the wrong first song. Existing [transition tests](/Users/g/Code/overplay/OverplayTests/PlaybackTransitionTests.swift) are the regression anchor. App and [CarPlay](/Users/g/Code/overplay/Overplay/CarPlaySupport/CarPlayCoordinator.swift:345) already route through the same action.

### PA-10 — Separate time sampling from full queue/metadata work

**Evidence:** [one-second monitor](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:410), [shared snapshot refresh](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:1716), [queue re-correlation guard](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:2657), [live queue snapshots](/Users/g/Code/overplay/Overplay/Playback/PlaybackPlayer.swift:84), [current-row update](/Users/g/Code/overplay/Overplay/Models/ActivePlaylistSnapshot.swift:111).

Every active timer tick enters the common reconciliation path. Even when re-correlation later returns early, it first materializes the live queue snapshots and sets/filters; snapshots include normalized title/artist metadata. Unchanged track metadata still goes through resolver/database reads. `updatingCurrentRow` maps and compares the full row array before determining that nothing changed. MusicKit events and explicit commands run this path as well.

**Change:** keep the required elapsed-time/accounting sample inexpensive. Cache a queue snapshot/index by observed generation, reuse it within one reconciliation pass, and do full work on queue/identity/membership changes with a bounded recovery check. Return early from current-row updating when the current identity tuple has not changed; patch old/new rows when it has. Preserve concrete player-reported changes, missed-event recovery, outgoing-session evaluation and hydration handling.

The project already records event versus timer reconciliation and tracks device evidence before reducing polling. Optimize the work per tick first. Do not simply delete the timer or slow accounting because events exist.

**Verify:** profile a large unchanged queue while scrolling; compare main-actor time per tick and queue snapshot builds per reconciliation. Re-run observation/reconciliation/transition tests and validate Lock Screen, Control Center, CarPlay and headset skips on device.

### PA-11 — Batch persistent queue-association work

**Evidence:** [PlaybackAssociationStore](/Users/g/Code/overplay/Overplay/Services/PlaybackAssociationStore.swift:28), [member construction](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:2808), [association recording loop](/Users/g/Code/overplay/Overplay/Services/PlaybackController.swift:2886).

For each metadata-matched entry, `record` loads/decodes the complete UserDefaults association array, scans it, and can encode/write it again. The array is capped at 2,048 entries, but learning a large queue can still repeat the whole operation once per learned association. Validation also nests scans of candidates and members. Correlation itself includes repeated candidate searches. These costs cluster around queue hydration/reissue, just when startup/selection is trying to settle.

**Change:** load the association store once per reconciliation generation, validate with keyed owner/metadata maps, merge a batch, and save once if changed. Index correlation candidates while preserving ambiguous-match rejection and submission/scope constraints. Retain the existing unchanged-snapshot guard.

**Verify:** a large reissued queue requires one batched association save rather than one per track. Keep tests for competing owners, changed metadata, expiry, account scope and partially hydrated queues. Optimize only after measuring how often metadata matching actually occurs on the affected device.

## Other background and UI work

### PA-12 — Make theme warmup opportunistic and stop rewriting the whole store per theme

**Evidence:** [sync warmup submission](/Users/g/Code/overplay/Overplay/Services/PlaylistSyncService.swift:888), [two-worker queue](/Users/g/Code/overplay/Overplay/Services/AlbumArtworkThemeWarmupService.swift:45), [512-pixel OCR](/Users/g/Code/overplay/Overplay/Presentation/AlbumArtworkTheme.swift:400), [theme-store write](/Users/g/Code/overplay/Overplay/Services/AlbumArtworkThemeStore.swift:86).

Inserted/changed theme inputs are queued after sync. Warmup is already bounded to two jobs and skips cached themes, but a large import can keep it busy for a long time. Theme generation uses Vision accurate text recognition as well as palette extraction. Each `setTheme` encodes and atomically rewrites the entire `themes.json`, whose limit is 10,000 entries. Filling K new themes into a growing single-file cache produces roughly quadratic cumulative serialization work. This runs off the main actor, but still competes for CPU, storage and artwork delivery.

**Change:** prioritize the playing/next-likely tracks and suspend speculative warmup during fast scrolling or playback startup. Batch/debounce theme-store persistence or store records individually. Reuse shared source artwork and avoid a duplicate nominal 128 variant. Keep the 512 OCR requirement until visual checks establish a cheaper equivalent. A palette-first/OCR-later design would need explicit visual acceptance because it can change the resulting theme.

**Verify:** count theme-store writes/bytes for a large import; measure CPU/energy while scrolling and selecting tracks; check representative artwork palettes and OCR-derived colors.

### PA-13 — Reduce repeated full-library video scans

**Evidence:** [VideoTrackCleanupService](/Users/g/Code/overplay/Overplay/Persistence/VideoTrackCleanupService.swift:29), [periodic preflight](/Users/g/Code/overplay/Overplay/Services/PeriodicPlaylistSyncService.swift:91), [per-playlist sync](/Users/g/Code/overplay/Overplay/Services/PlaylistSyncService.swift:140), [startup](/Users/g/Code/overplay/Overplay/App/AppStartupViewModel.swift:37).

Cleanup fetches every track and attempts to decode its stored MusicKit playback payload to identify videos. It runs at startup, before a periodic cycle, and at multiple points inside each playlist sync. Even an unchanged remote playlist can incur a pre-fetch full-library scan. This is repeated main-actor decoding, and it was added on 23 September.

**Change:** perform at most one necessary legacy sweep per cycle; reuse its result. Validate new/imported payloads at their ingestion boundary. Track a cheap local classification/revision or rescan only changed records so late CloudKit imports from older clients are still checked. A permanent one-time migration flag alone would violate the existing late-import protection.

**Verify:** many unchanged playlists should not cause many whole-library decodes. Retain song-only import and late video-delivery regression coverage. Profile startup duplicate detection/history maintenance separately before assigning them the same priority; their existence alone does not establish a bottleneck.

### PA-15 — Avoid constructing full-list identity strings on body updates

**Evidence:** [playlistTrackIDsKey/detailPresentationKey](/Users/g/Code/overplay/Overplay/Views/PlaylistManagementView.swift:238), [presentation tasks](/Users/g/Code/overplay/Overplay/Views/PlaylistManagementView.swift:162).

The detail rows are already memoized, but the cache key maps every item to a long string, sorts it, and joins it. The same key is evaluated for track loading and embedded in the detail key. Scroll-phase changes cause body reevaluation. Count changes update item timestamps and can therefore trigger a track refetch even when track membership and metadata are unchanged. A changed current-track highlight can also rebuild all row presentation values.

**Change:** separate membership, metadata/counts, order and current-row revisions. Fetch tracks only when relevant IDs/metadata change. Update row values by ID and patch the previous/new current row instead of rebuilding the full presentation. Make sure metadata-only edits and imported updates remain observable; simply using `tracks.count` is not a safe replacement. Keep SwiftUI `List` and stable row IDs unless profiling establishes a need for a larger layout change.

**Verify:** count track fetches, key builds and row rebuilds while changing scroll phase, current track and one counter. Add presentation invalidation tests for unchanged membership with changed title/artwork/counts.

## Existing safeguards to preserve

- Artwork decode is already off-main and downsampled, disk downloads already coalesce for identical keys, and the artwork manifest already batches writes. Improve those boundaries rather than replacing them blindly.
- Normal playlist sync has a 30-minute freshness gate, a remote modification-date shortcut, 500 ms spacing, and periodic yielding. Playlist metadata fetching has a 60-second shared cache/in-flight gate. The new count-entry fallback is a separate path that needs comparable coordination.
- Identity enrichment has batching, caching and a three-request limit. Full library count discovery has a 15-minute cooldown; current-track retries and recent-history attempts have a one-minute bound. The missing gates described above are more specific than “all APIs are unthrottled.”
- Now Playing metadata already uses change/drift checks and a 60-second re-anchor. It is not unconditionally rewritten every second. CarPlay already avoids observing elapsed time for button refreshes.
- History already pages ordinary events. Search runs on submitted searches, rather than automatically issuing a request on every keystroke. Neither is the first place to look for uncontrolled request volume.
- Preserve shared playback actions and state across app, CarPlay, remote commands and externally observed MusicKit changes. Retain accounting, full-queue shuffle/repeat, account scoping, monotonic counts, unknown counts and reset correctness.

## Measurement and implementation order

1. **Capture a baseline with the existing activity diagnostics plus targeted signposts.** Add tap-to-command, queue preparation, scope lookup, assignment/replace, `play()` wait, confirmation and presentation timings. Add image memory/disk/network hit counters, decode queue delay, actual dimensions and bytes, count-query/state-decode totals, and full snapshot/template rebuild counts. Current MusicKit activity timers are useful but do not include all pre-command CPU and scope work. Player status/time movement is a useful proxy; physical listening establishes first audible output.
2. **First change set: PA-01, PA-02, PA-03, PA-07.** These address explicit cache behavior and unnecessary presentation churn. Keep image scheduling bounded while removing scroll suppression; PA-04 belongs with any prefetch expansion.
3. **Second change set: PA-05 and PA-06.** These target the strongest recent CPU/database/API regression candidates. Establish deterministic fetch/call-count tests alongside the existing correctness suites before changing cadence policy.
4. **Third change set: PA-08 and PA-09.** Time both selection paths, decouple scope verification, and reuse preparation while preserving the full queue and shared user action.
5. **Then PA-10 through PA-16 according to measured cost.** Theme I/O, video scans and association persistence should move earlier if traces show they dominate the user's workload.

Use a physical iPhone/iPad with the user's representative playlist sizes, and synthetic 100/1,000/5,000-row stores for deterministic scaling checks. Compare identical optimized builds, data and network conditions. Record cold-cache, disk-warm and memory-warm scrolls; startup with counts already known versus unresolved; idle versus active count refresh; and foregrounding after a long pause. Profile rapid forward/reverse scrolling, mini-player expansion, same-queue taps, different-playlist taps, Next/Previous, and CarPlay/system-control changes.

Report p50/p95 action latency, main-thread hitch duration, image-ready latency, peak/resident image memory, database fetches, state decodes, API calls and bytes. Use 8.3 ms/16.7 ms frame intervals as 120 Hz/60 Hz reference budgets, not promises about a particular device's refresh rate. Avoid wall-clock assertions in ordinary unit tests: assert bounded calls, correct cache sharing, stable no-op revisions and preserved behavior; use a dedicated performance run for timing.

The repository's canonical correctness check is `xcodebuild test -project Overplay.xcodeproj -scheme Overplay -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`. Future code changes should run proportionate focused tests and compile affected targets. Live MusicKit timing and playback behavior require a suitable physical device; simulator playback is not a completion gate under this project's policy.
