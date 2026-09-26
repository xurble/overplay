# Performance changes and measurement guide — 25 September 2026

This implements the code-evidenced improvements from [the audit](PERFORMANCE_AUDIT_2026-09-25.md), adds CarPlay track artwork, and measures the remaining playback and scrolling suspects. The audit describes the original baseline, not the resulting implementation. These are engineering changes and diagnostic boundaries; no physical-device before/after speedup is claimed.

## Changes made

| Audit area | Implementation | Reason and boundary |
|---|---|---|
| PA-01: blank artwork while scrolling | Removed scroll-phase suppression. `ArtworkView` can show a decoded memory hit synchronously and starts asynchronous loading even while scrolling. | Scrolling no longer deliberately hides already cached images or defers every miss until scrolling ends. Cold disk/network images still arrive asynchronously. |
| PA-02: useful sizes | ImageIO makes actual aspect-preserving 128- and 512-pixel JPEG variants, capped on their longest edge, off the main actor. Smaller sources are not upscaled. Rows, mini player, search and playlist artwork request 128; expanded artwork and recognition request 512. | Old “size” keys did not resize the downloaded bytes. Cache key v2 discards managed legacy representations. Source downloads use the provided URL; this change does not rewrite arbitrary CDN URL formats. Search now obtains a 512 source and later non-nil artwork metadata can replace an older small source. |
| PA-02: progressive large player | Show the available 128 image while requesting 512, then replace it. Keep the thumbnail on a large-image failure. | A thumbnail is useful immediately. A bounded recent 512 disk cache avoids repeated downloads and recognition work; it is not retained for the entire library indefinitely. |
| PA-03/04: shared, bounded image work | `ArtworkImagePipeline` shares decoded images by normalized source URL and size, independent of playlist. NSCache has a 24 MiB decoded-cost limit; disappearing SwiftUI views release their image state. Downloads coalesce across sizes; display decodes coalesce per size. Four source jobs, two variant-processing jobs, and two display-decode jobs run at once. Gates favor waiting work with higher requested priority, FIFO at equal priority. Failed sources have a 60-second cooldown. | Avoid duplicate downloads/decodes, oversized decoded row images, and unrestricted simultaneous work. Source permits remain held through variant processing, bounding buffered source data. The two decode limits are separate, not a combined two-worker cap. Shared jobs finish even if a single consumer disappears. |
| PA-16: access and eviction | Memory use records disk access without reading image bytes. Playback centrally sets the protected playlist. Its 128 thumbnails are protected; 512 variants have a 32 MiB recent-access budget inside the overall 250 MiB disk budget. Missing thumbnails can be regenerated from a retained 512 file offline. | Visible reuse now affects eviction. Protection is not limited to a single prefetch request. The requested file and protected thumbnails can exceed the nominal disk budget; the cache is disposable, not a permanent offline library. |
| CarPlay artwork | Track rows use the same 128 cache/pipeline. Memory hits appear immediately; one asynchronous request at a time fills remaining rows in display order, stopping at CarPlay’s displayed-item limit. The playing indicator is trailing, alongside artwork. Replacing a list or disconnecting cancels its row-update loop. | No separate CarPlay download or decode cache, and no task per track queued upfront. Shared work already underway may complete; canceled loops cannot update obsolete rows or request further ones. CarPlay does not expose row visibility here, so this is ordered loading rather than visibility-based prefetch. |
| PA-05: repeated count reads | A synchronous, context-scoped evidence projection batch-fetches relevant records and donor lineage, decodes each once, and memoizes joined states. Used by count refresh/application, active snapshots, playlist detail presentation and shared track summaries (including CarPlay’s non-playing playlists). Appends update the projection; new lineage links invalidate it. | Replaces per-row SwiftData queries in the largest bulk paths. No long-lived count cache survives imports, resets, or another context. Uncovered IDs fall back to live reads. Other isolated getters remain measured. |
| PA-06: refresh bursts | The shared bulk count service rejects overlapping work and triggers within 15 seconds. Per-playlist fallback requests join in-flight work, reuse successful observations for 60 seconds, and cool down failed attempts for 60 seconds. Original observation timestamps survive reuse. | Avoid repeat whole-playlist fetches from overlapping triggers without allowing cached pre-reset evidence to cross a reset. Current-track priority discovery remains independent of the bulk gate. The periodic cadence itself is unchanged. |
| PA-07: no-op publishing | Rebuilt active snapshots retain their revision when rows/scope/playlist are unchanged. Count refresh does not unconditionally bump the metadata version. CarPlay coalesces save/observation-driven list refreshes over 100 ms. | Prevent unnecessary SwiftUI/CarPlay invalidation. Snapshot comparison still requires building a candidate; its cost is measured. Explicit playback actions still refresh immediately. |
| PA-10: ordinary ticks | Current-row patching skips repeated identity/revision tuples. | Avoid mapping every row on unchanged playback ticks. Full player reconciliation remains intact to preserve external track-change handling. |
| PA-11: association writes | Learned associations are collected and saved once per reconciliation batch; member/snapshot lookup uses ID dictionaries. Same-owner reuse and competing-owner rejection remain unchanged. | Removes repeated whole-store JSON encode/write work for each learned queue entry. Validation scans remain a measurement candidate. |
| PA-12: recognition and theme storage | Removed sync-triggered recognition of every changed track. Themes remain generated on player demand from 512 artwork. Theme JSON writes are batched for one second and flushed with artwork metadata on background entry. | Avoid competing with scrolling/playback immediately after a large sync and avoid rewriting the entire theme store for every result. |
| PA-13: video cleanup | Automatic cycles perform their existing full scan once; their per-playlist syncs skip repeating it. Multi-source and all-linked syncs likewise avoid per-source full scans. Known video IDs use an identity-only cleanup pass, with no playback JSON decoding. Standalone sync/startup retain full cleanup. | Preserve late-arriving legacy-video cleanup and local-only deletion while eliminating redundant library decodes. |
| PA-14: discovery matching | Build a normalized alias/ISRC/metadata index once off the main actor for each full-library discovery response. | Avoid normalizing and scanning the entire library separately for every unresolved track. Matching ambiguity and duration rules are unchanged. |
| PA-15: view refresh keys | Replace sorted, concatenated whole-playlist strings with typed revisions. Track fetching is keyed only by the set of referenced track IDs. Presentation revision still observes item, source and track metadata. | Counter or provenance changes rebuild presentation without refetching the same TrackRecord set. Keys are still linear in row count; measure before introducing broader persistent presentation caches. |

## Playback behavior deliberately preserved

Selecting a track in the matching live playlist and active/retired scope already uses the shared `playPlaylist(...startingAt:)` action on iPhone/iPad and CarPlay. It attempts to select the existing queue entry. Selecting the current track resumes without restarting. A playlist/scope mismatch, empty local mapping, target absent after reconciliation, or a concrete missing native entry can require queue replacement. Replacement still starts at the selected track. The existing transition, outgoing-session accounting and external-player reconciliation rules remain in place.

The following require measurements before changing their behavior:

* **PA-08, account/storefront resolution:** still awaited before a new queue. Removing this check or reusing stale authorization scope could apply learned IDs across accounts or storefronts. Measure its time first; do not describe it as eliminated.
* **PA-09, queue preparation:** full cached MusicKit track deserialization remains on a required replacement. A decoded queue cache needs explicit invalidation for playlist edits, aliases and restored playback. Preparation now has its own timer.
* **PA-09, native selection:** assigning `currentEntry`, `play()`, and waiting for player confirmation are timed separately. Fast skip-next does not establish which of these makes arbitrary selection slow.
* **PA-10, full reconciliation:** the actual player still wins over local queue assumptions. Polling/reconciliation cadence is unchanged; the cheap current-row guard is the safe optimization made now.
* **PA-01/04, prefetch and cancellation:** no broad speculative prefetch was added. Measure remaining misses and gate wait before selecting a nearby prefetch window, changing concurrency, or canceling shared jobs when their last consumer disappears.
* **PA-06, periodic traffic:** bulk refresh frequency and per-playlist polling may still be excessive for large libraries. Measure request counts and unchanged work before changing freshness policy further.

## Instrumentation

`PerformanceSpan` emits an Instruments signpost interval under category **Performance**, named **Overplay work**, with the operation name in the begin message. It also records monotonic elapsed time in the existing `MusicKitActivityLog`. Timings are elapsed wall time, not CPU time; asynchronous intervals include waiting.

The Full Activity Report now includes `timed`, `avg` and `max` milliseconds for each operation with samples. Minute tallies retain count, timed sample count, summed duration and maximum duration. Older persisted tallies decode without these optional timing fields. Local threshold-selected samples are excluded from the report’s API latency-degradation heuristics. Routine performance events are tallied, not individually retained; performance spans of at least 100 ms are also retained as notable samples. Selection/path/scope/confirmation events are individually retained. Local performance observations are excluded from the headline API-call total.

Retention remains four hours of minute buckets and the most recent 250 notable events. The report's average/max cover retained samples, not a selected trace or a percentile distribution. Nested timings overlap: never add all operation totals together as total latency. A caller joining shared work does not imply a second network call.

| Operations | What to look for / next action |
|---|---|
| `artworkMemoryHit`, `artworkDiskHit`, existing `artworkDownload` | Repeated visits should move toward memory hits. Downloads on a warm playlist suggest eviction/source URL changes. Download magnitudes are source bytes, not resized disk bytes. |
| `artworkRequestCoalesced`, `artworkRetrySkipped` | Coalescing should increase when surfaces request the same album. Retry skips during an outage are intentional, not additional API calls. |
| `artworkWorkWait`, `artworkDecode`, `artworkCacheWrite` | Separate scheduling pressure, image processing and disk writes. Details distinguish source variants from display decoding. Long waits with short decode times suggest excess queued work/priority; expensive decodes warrant a Time Profiler capture. |
| `playCountRefresh`, `playCountRefreshSkipped`, `playCountApply`, `playCountEvidenceRead`, `playCountDiscovery` | Compare end-to-end refresh with local application/read costs. Evidence details distinguish batch versus single reads; magnitudes identify batch size. Pair with existing library/playlist fetch operations to distinguish API waits from main-actor work. |
| `playlistSnapshotBuild`, `playlistSnapshotUnchanged`, `playlistPresentation` | Frequent unchanged snapshots mean candidate construction is still wasted work. Use this evidence to decide whether to propagate a reliable change set instead of rebuilding. |
| `playbackSelection`, `playbackSelectionPath` | Each row selection gets a generated correlation UUID (not a track/account identifier). Path details identify `playlistMismatch`, `scopeMismatch`, `mappingEmpty`, `inQueueAttempt`, `targetMissingAfterReconciliation`, or `entryMissingInPlayer`. Correlate retained stage samples by that UUID. |
| `playbackScopeResolution`, `playbackQueuePreparation` | Attribute the time before queue setup to scope lookup or preparation. These should normally be absent from a successful in-queue selection. |
| `playerEntryAssignment`, `playerSelectionPlay`, `playbackConfirmation` | Attribute native arbitrary-track selection latency to entry assignment, MusicKit play, or observation/confirmation. An entry assignment timer is synchronous; a play timer includes MusicKit suspension. |
| `playbackSnapshot`, existing reconciliation operations | Identify expensive periodic or external-event reconciliation while scrolling. Snapshot magnitude is mapped queue size. Preserve outgoing-track accounting and cross-surface reconciliation when optimizing. |
| `playbackAssociationWrite`, `artworkThemeGeneration`, `artworkThemePersistence`, `videoCleanup` | Check background competition and write amplification. Video details distinguish full scans from known-ID passes. Theme generation is demand work; whole-library recognition should no longer follow sync. |

All new detail strings describe stages/counts and generated trace IDs. They do not record artwork URLs, account IDs or tokens. Detached variant/index work does not inherit task-local selection correlation automatically; aggregate/signpost measurements remain available.

## How to investigate a future report

1. Open **Settings → Apple Music Call Activity**. Copy the existing **Full Activity Report** before clearing it if it contains useful history. Clear recorded activity for a clean reproduction.
2. Record device model, build, playlist size, connection, foreground/background state, and whether artwork was warm. Reproduce one scenario: fast scroll and reverse; reopen the same list; start a playlist; select another track within it; select the current paused track; switch active/retired scope; repeat via CarPlay.
3. Tap **Refresh**, expand **Full Activity Report**, and copy the selectable text. Avoid mixing a ten-minute sync session with a single tap when interpreting totals. Note the real-world symptom time so notable events can be matched.
4. For a slow row selection, start at `playbackSelectionPath`. Determine whether a replacement actually occurred, then compare scope/preparation, native assignment/play, and confirmation. A high overall selection time with low recorded stages means additional controller/database work needs a narrower span.
5. For stutter, attach Instruments to a physical-device Development build. Record **Time Profiler**, **SwiftUI**, and signpost/Points of Interest data. Filter to the app's **Performance** category and inspect the main thread during the hitch. Use Allocations for image-memory pressure. The full report alone cannot prove a frame hitch or identify CPU stacks.
6. Keep warm-cache and cold-cache runs separate. Clearing Recorded Activity resets diagnostics, not artwork. Use a previously unseen album/list or a disposable development install for a cold run; do not treat a successful cache hit as a network benchmark.
7. Validate CarPlay artwork and trailing indicator on a physical head unit or supported CarPlay environment, including quick navigation/disconnect and missing artwork. Simulator unit tests check row configuration and shared image behavior, not real head-unit layout or live MusicKit playback.

## Verification

Regression coverage exercises actual resized image dimensions/aspect ratio; both-size download sharing; offline thumbnail regeneration; retry cooldown/recovery; cross-playlist decoded reuse; cache persistence/eviction; scoped evidence and donor-link invalidation; refresh cooldown; association conflict handling; duration aggregation; and CarPlay artwork alongside its playing indicator. Existing shared playback transition, reset, convergence and adapter tests are included in the full run.

The full suite passed: **788 tests, 847 parameterized executions, zero failures or skips**, on the iPhone 17 Pro simulator running iOS 26.5 (Xcode 26.5). A pre-existing observation correctness test passed alone but exceeded its two-second deadline when sharing the main actor with the full suite; its deadline is now ten seconds, with no production observation timing change. Theme-store debounce tests use an injected long delay and explicit flush instead of racing the scheduler. Existing artwork fixtures were replaced with real image bytes so resizing is verified.

The final source also passed an **unsigned generic iOS device build** and **36 focused artwork/CarPlay/presentation tests (38 parameterized executions)**. The first focused parallel run reported `Test crashed with signal term` at the runner level even though its modern result summary listed passing tests. Rerunning with parallel simulator workers disabled completed successfully with exit code 0; no production code was changed to bypass that termination. `git diff --check` passed.

Commands used (all shell commands through the required `rtk` wrapper):

```sh
rtk proxy xcodebuild -project Overplay.xcodeproj -scheme "Overplay Dev" \
  -destination "platform=iOS Simulator,id=A5C05D99-49EB-4F82-9664-CE4538D506B9" \
  -derivedDataPath /tmp/overplay-performance-derived test

rtk proxy xcodebuild -project Overplay.xcodeproj -scheme "Overplay Dev" \
  -destination "generic/platform=iOS" \
  -derivedDataPath /tmp/overplay-performance-device CODE_SIGNING_ALLOWED=NO build

rtk proxy xcodebuild -project Overplay.xcodeproj -scheme "Overplay Dev" \
  -destination "platform=iOS Simulator,id=A5C05D99-49EB-4F82-9664-CE4538D506B9" \
  -derivedDataPath /tmp/overplay-performance-derived -parallel-testing-enabled NO test \
  -only-testing:OverplayTests/ArtworkCacheServiceTests \
  -only-testing:OverplayTests/ArtworkImagePipelineTests \
  -only-testing:OverplayTests/CarPlayLibrarySnapshotTests \
  -only-testing:OverplayTests/PlaylistPresentationBuilderTests \
  -only-testing:OverplayTests/CarPlayPlaylistSectionFactoryTests
```

The installed simulator is named “Overplay Apple Count Sync Tests”; its model is iPhone 17 Pro. The configured bare simulator name was not available, so the explicit installed UUID was used. Build/test logs are in `/tmp/overplay-performance-final-test.log`, `/tmp/overplay-performance-focused-serial-test.log`, and `/tmp/overplay-performance-device-build.log`. The full test result bundle is `/tmp/overplay-performance-derived/Logs/Test/Test-Overplay Dev-2026.09.25_19-33-37-+0100.xcresult`.

Live MusicKit latency, visible scrolling smoothness, and head-unit rendering still require device measurements using the procedure above.
