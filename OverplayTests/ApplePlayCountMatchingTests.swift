import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Apple play count discovery")
struct ApplePlayCountMatchingTests {
    private func metadata(aliases: [String] = [], title: String = "Song", artist: String = "Artist",
                          album: String? = "Album", duration: Double? = 180, isrc: String? = nil) -> ApplePlayCountMatchTrack {
        ApplePlayCountMatchTrack(aliases: aliases, title: title, artist: artist, album: album, duration: duration, isrc: isrc)
    }

    private func entry(_ id: String = "i.found", count: Int? = 10,
                       track: ApplePlayCountMatchTrack? = nil) -> ApplePlayCountLibraryEntry {
        ApplePlayCountLibraryEntry(track: track ?? metadata(aliases: [id]), observation:
            MusicLibraryPlaybackObservation(aliases: [id], snapshot:
                MusicLibraryPlaybackSnapshot(musicItemID: id, playCount: count, lastPlayedDate: nil)))
    }

    @Test("Library scan finds catalog links even when the ID query missed them")
    func catalogLink() {
        let found = entry(track: metadata(aliases: ["i.found", "123"], title: "Different display title"))
        #expect(ApplePlayCountMatcher.matches(metadata(aliases: ["123"]), in: [found]).count == 1)
    }

    @Test("A unique ISRC bridges album editions")
    func recordingCode() {
        let found = entry(track: metadata(album: "Compilation", isrc: "GB1234567890"))
        #expect(ApplePlayCountMatcher.matches(metadata(isrc: "gb1234567890"), in: [found]).count == 1)
        #expect(ApplePlayCountMatcher.matches(metadata(isrc: "gb1234567890"), in: [found], allowRecordingCode: false).isEmpty)
    }

    @Test("Normalized metadata and close duration recover a unique library song")
    func metadataMatch() {
        let found = entry(track: metadata(title: " SÓNG ", artist: "ARTIST", duration: 181))
        #expect(ApplePlayCountMatcher.matches(metadata(), in: [found]).count == 1)
    }

    @Test("Ambiguous library copies remain unknown even if only one exposes a count")
    func ambiguity() {
        #expect(ApplePlayCountMatcher.matches(metadata(), in: [entry(), entry("i.other", count: nil)]).isEmpty)
        let a = entry(track: metadata(isrc: "recording"))
        let b = entry("i.other", track: metadata(isrc: "recording"))
        #expect(ApplePlayCountMatcher.matches(metadata(isrc: "recording"), in: [a, b]).isEmpty)
    }

    @Test("Different versions, albums, durations and recording codes are rejected")
    func rejectsNearMatches() {
        for other in [metadata(title: "Song (Live)"), metadata(artist: "Other"), metadata(album: "Other"),
                      metadata(duration: 190), metadata(duration: nil), metadata(album: nil), metadata(isrc: "other")] {
            #expect(ApplePlayCountMatcher.matches(metadata(isrc: "original"), in: [entry(track: other)]).isEmpty)
        }
    }

    private func fixture(_ context: ModelContext) throws -> (TrackRecord, PlaylistItemRecord) {
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let track = TrackRecord(catalogID: "123", title: "Song", artistName: "Artist", albumTitle: "Album", durationSeconds: 180)
        let item = PlaylistItemRecord(playlistID: bucket.id, trackID: track.id, playthroughCount: 2)
        context.insert(track)
        context.insert(item)
        try context.save()
        return (track, item)
    }

    @Test("back-to-back bulk refreshes are throttled without blocking current-track discovery")
    func bulkRefreshCooldown() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, _) = try fixture(context)
        var queries = 0
        let service = ApplePlayCountSyncService(minimumRefreshInterval: 60,
            fetchRecentlyPlayed: { [] }, fetchPlaylist: { _ in [] }, fetchLibrary: { _ in [] }, fetch: { _ in
                queries += 1
                return []
            })
        _ = await service.refresh(in: context)
        _ = await service.refresh(in: context)
        #expect(queries == 1)
        _ = await service.refreshCurrentTrack(track.id, in: context)
        #expect(queries == 2)
    }

    @Test("Discovered counters seed existing plays, persist their ID, and refresh directly next time")
    func discoveryAndRefresh() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, item) = try fixture(context)
        var scans = 0
        var queries: [[String]] = []
        let service = ApplePlayCountSyncService(fetchLibrary: { title in
            #expect(title == nil)
            scans += 1
            return [entry()]
        }, fetch: { ids in
            queries.append(ids)
            return ids.contains("i.found") ? [entry(count: 12).observation] : []
        })
        #expect(await service.refresh(in: context) == 1)
        #expect(item.applePlayCount == 2)
        #expect(track.identityAliases.isEmpty && track.libraryID == nil)
        #expect(await service.refresh(in: context) == 1)
        #expect(item.applePlayCount == 4)
        #expect(queries.last?.contains("i.found") == true)
        #expect(scans == 1)
    }

    @Test("Discovery failure preserves direct results and does not seed missing metadata")
    func discoveryFailure() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (_, item) = try fixture(context)
        let service = ApplePlayCountSyncService(fetchLibrary: { _ in throw CancellationError() }, fetch: { _ in [] })
        #expect(await service.refresh(in: context) == 0)
        #expect(item.applePlayCount == nil)
    }

    @Test("Playing song discovery bypasses bulk cooldown and throttles repeated misses")
    func priorityLookup() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, item) = try fixture(context)
        var titles: [String?] = []
        var found = false
        let service = ApplePlayCountSyncService(fetchLibrary: { title in
            titles.append(title)
            return found ? [entry()] : []
        }, fetch: { _ in [] })
        _ = await service.refresh(in: context)
        let now = Date.now
        #expect(await service.refreshCurrentTrack(track.id, in: context, now: now) == 0)
        found = true
        #expect(await service.refreshCurrentTrack(track.id, in: context, now: now.addingTimeInterval(1)) == 0)
        #expect(titles.count == 2 && titles[0] == nil && titles[1] == "Song")
        #expect(await service.refreshCurrentTrack(track.id, in: context, now: now.addingTimeInterval(61)) == 1)
        #expect(item.applePlayCount == 2)
    }

    @Test("A playing track resolves while the bulk library scan is still waiting")
    func priorityDuringBulkScan() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, item) = try fixture(context)
        var releaseBulk: CheckedContinuation<[ApplePlayCountLibraryEntry], Never>?
        let service = ApplePlayCountSyncService(fetchLibrary: { title in
            if title != nil { return [entry()] }
            return await withCheckedContinuation { releaseBulk = $0 }
        }, fetch: { _ in [] })
        let bulk = Task { await service.refresh(in: context) }
        while releaseBulk == nil { await Task.yield() }
        #expect(await service.refreshCurrentTrack(track.id, in: context) == 1)
        #expect(item.applePlayCount == 2)
        releaseBulk?.resume(returning: [])
        _ = await bulk.value
        #expect(item.applePlayCount == 2)
    }

    @Test("Reset before first observation preserves discovery and seeds current plays", arguments: [false, true], [0, 3])
    func discoveryAfterReset(priority: Bool, plays: Int) async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, item) = try fixture(context)
        try PlaylistItemRepository.resetAllStats(in: context)
        #expect(item.applePlayCount == nil)
        #expect(item.applePlayCountResetAt != nil)
        let initialRecordCount = try context.fetchCount(FetchDescriptor<ApplePlayCountRecord>())
        #expect(try ApplePlayCountSyncService.apply([], startedAt: .now, in: context) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ApplePlayCountRecord>()) == initialRecordCount)
        item.playthroughCount = plays
        let service = ApplePlayCountSyncService(fetchLibrary: { title in
            #expect((title != nil) == priority)
            return [entry()]
        }, fetch: { _ in [] })
        let changed = priority
            ? await service.refreshCurrentTrack(track.id, in: context)
            : await service.refresh(in: context)
        #expect(changed == 1)
        #expect(item.applePlayCount == plays)
        let update = ApplePlayCountSyncService(fetchLibrary: { _ in [] }, fetch: { ids in
            #expect(ids.contains("i.found"))
            return [entry(count: 11).observation]
        })
        _ = await update.refresh(in: context)
        #expect(item.applePlayCount == plays + 1)
    }

    private func playlistObservation(count: Int?) -> MusicLibraryPlaybackObservation {
        MusicLibraryPlaybackObservation(aliases: ["123"], snapshot:
            MusicLibraryPlaybackSnapshot(musicItemID: "123", playCount: count,
                lastPlayedDate: nil, playlistEntryEvidence: true))
    }

    private func recentObservation(_ id: String = "123", count: Int?) -> MusicLibraryPlaybackObservation {
        MusicLibraryPlaybackObservation(aliases: [id], snapshot:
            MusicLibraryPlaybackSnapshot(musicItemID: id, playCount: count,
                lastPlayedDate: nil, recentlyPlayedEvidence: true))
    }

    @Test("Recently played resolves unattributed songs and refreshes their counts", arguments: [false, true])
    func recentFallback(priority: Bool) async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, item) = try fixture(context)
        #expect(item.sourceMusicPlaylistIDs.isEmpty)
        var logs: [String] = []
        let service = ApplePlayCountSyncService(fetchRecentlyPlayed: {
            [recentObservation(count: 10)]
        }, logRecentLookup: { logs.append($0) }, fetchPlaylist: { _ in
            Issue.record("An unattributed song should not require a playlist")
            return []
        }, fetchLibrary: { _ in [] }, fetch: { _ in [] })
        let changed = priority ? await service.refreshCurrentTrack(track.id, in: context) : await service.refresh(in: context)
        #expect(changed == 1)
        #expect(item.applePlayCount == 2)
        #expect(logs.contains { $0.contains("count=10") })
        #expect(track.libraryID == nil && track.identityAliases.isEmpty)
        let next = ApplePlayCountSyncService(fetchRecentlyPlayed: {
            [recentObservation(count: 12), recentObservation(count: 12)]
        }, fetchLibrary: { _ in [] }, fetch: { ids in
            #expect(!ids.contains { $0.hasPrefix("recent-count:") })
            return []
        })
        _ = await next.refresh(in: context)
        #expect(item.applePlayCount == 4)
        #expect(item.applePlayCountState?.counters.count == 1)
    }

    @Test("Recent history logs missing songs separately from nil counts and retries after a minute")
    func recentProbeDiagnostics() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, item) = try fixture(context)
        var logs: [String] = []
        var observations = [recentObservation("other", count: 100)]
        var queries = 0
        let service = ApplePlayCountSyncService(fetchRecentlyPlayed: {
            queries += 1
            return observations
        }, logRecentLookup: { logs.append($0) }, fetchLibrary: { _ in [] }, fetch: { _ in [] })
        let now = Date.now
        _ = await service.refreshCurrentTrack(track.id, in: context, now: now)
        #expect(item.applePlayCount == nil)
        #expect(logs.last?.contains("not returned") == true)
        observations = [recentObservation(count: nil)]
        _ = await service.refreshCurrentTrack(track.id, in: context, now: now.addingTimeInterval(61))
        #expect(item.applePlayCount == nil)
        #expect(logs.last?.contains("count=nil") == true)
        observations = [recentObservation(count: 0)]
        _ = await service.refreshCurrentTrack(track.id, in: context, now: now.addingTimeInterval(62))
        #expect(item.applePlayCount == nil)
        #expect(queries == 2)
        _ = await service.refreshCurrentTrack(track.id, in: context, now: now.addingTimeInterval(122))
        #expect(item.applePlayCount == 2)
        #expect(logs.last?.contains("count=0") == true)
    }

    @Test("A cached recent-history result cannot restore a count after a reset")
    func recentCacheAfterReset() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, item) = try fixture(context)
        var queries = 0
        let service = ApplePlayCountSyncService(fetchRecentlyPlayed: {
            queries += 1
            return [recentObservation(count: 10)]
        }, fetchLibrary: { _ in [] }, fetch: { _ in [] })
        _ = await service.refreshCurrentTrack(track.id, in: context)
        #expect(item.applePlayCount == 2)
        try PlaylistItemRepository.resetAllStats(in: context)
        _ = await service.refresh(in: context)
        #expect(queries == 1)
        #expect(item.applePlayCount == 0)
    }

    @Test("Recent query failures are throttled and preserve unknown counts")
    func recentFailure() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, item) = try fixture(context)
        var queries = 0
        var logs: [String] = []
        let service = ApplePlayCountSyncService(fetchRecentlyPlayed: {
            queries += 1
            throw PlaylistSyncError.playlistNotFound
        }, logRecentLookup: { logs.append($0) }, fetchLibrary: { _ in [] }, fetch: { _ in [] })
        _ = await service.refreshCurrentTrack(track.id, in: context)
        _ = await service.refresh(in: context)
        #expect(queries == 1)
        #expect(item.applePlayCount == nil)
        #expect(logs.contains { $0.contains("probe failed") })
    }

    @Test("Recent, playlist and library evidence share increases across devices")
    func recentSourceJoin() throws {
        let now = Date.now
        var recent = ApplePlayCountState(initialCount: 1, originID: UUID())
        recent.observe(musicItemID: "recent-count:123", count: 10, at: now,
                       aliases: ["123"], isRecentlyPlayedCount: true)
        recent.observe(musicItemID: "recent-count:123", count: 12, at: now,
                       aliases: ["123"], isRecentlyPlayedCount: true)
        var playlist = ApplePlayCountState(initialCount: 1, originID: UUID())
        playlist.observe(musicItemID: "playlist-count:123", count: 20, at: now,
                         aliases: ["123"], isPlaylistCount: true)
        playlist.observe(musicItemID: "playlist-count:123", count: 23, at: now,
                         aliases: ["123"], isPlaylistCount: true)
        var library = ApplePlayCountState(initialCount: 1, originID: UUID())
        library.observe(musicItemID: "i.song", count: 100, at: now, aliases: ["123", "i.song"])
        library.observe(musicItemID: "i.song", count: 103, at: now, aliases: ["123", "i.song"])
        var joined = try #require(ApplePlayCountState.joined([recent, playlist, library]))
        joined.advance()
        #expect(joined.count == 4)
        var reverse = try #require(ApplePlayCountState.joined([library, playlist, recent, recent]))
        reverse.advance()
        #expect(joined == reverse)
        joined.observe(musicItemID: "recent-count:123", count: 9, at: now,
                       aliases: ["123"], isRecentlyPlayedCount: true)
        #expect(joined.count == 4)
        let restored = try JSONDecoder().decode(ApplePlayCountState.self, from: JSONEncoder().encode(joined))
        #expect(restored == joined)
    }

    @Test("Playlist-only songs resolve during playback or bulk refresh without a library match", arguments: [false, true])
    func playlistFallback(priority: Bool) async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, item) = try fixture(context)
        item.sourceMusicPlaylistIDs = ["p.tiktok"]
        var queried: [String] = []
        let service = ApplePlayCountSyncService(fetchPlaylist: { id in
            queried.append(id)
            return [playlistObservation(count: 10)]
        }, fetchLibrary: { _ in [] }, fetch: { _ in [] })
        let changed = priority ? await service.refreshCurrentTrack(track.id, in: context) : await service.refresh(in: context)
        #expect(changed == 1)
        #expect(queried == ["p.tiktok"])
        #expect(item.applePlayCount == 2)
        #expect(track.libraryID == nil && track.identityAliases.isEmpty)

        // A subsequent refresh still queries the playlist after the dash has
        // resolved, even though there is no corresponding library song.
        let refresh = ApplePlayCountSyncService(fetchPlaylist: { _ in
            [playlistObservation(count: 12), playlistObservation(count: 12)]
        }, fetchLibrary: { _ in [] }, fetch: { ids in
            #expect(!ids.contains { $0.hasPrefix("playlist-count:") })
            return []
        })
        _ = await refresh.refresh(in: context)
        #expect(item.applePlayCount == 4)
        #expect(item.applePlayCountState?.counters.count == 1)
    }

    @Test("Missing playlist counts stay unknown; library query errors still allow playlist lookup")
    func playlistNilAndLibraryFailure() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, item) = try fixture(context)
        item.sourceMusicPlaylistIDs = ["p.tiktok"]
        var count: Int?
        let service = ApplePlayCountSyncService(fetchPlaylist: { _ in
            [playlistObservation(count: count)]
        }, fetchLibrary: { _ in [] }, fetch: { _ in throw PlaylistSyncError.playlistNotFound })
        let now = Date.now
        _ = await service.refreshCurrentTrack(track.id, in: context, now: now)
        #expect(item.applePlayCount == nil)
        count = 0
        _ = await service.refreshCurrentTrack(track.id, in: context, now: now.addingTimeInterval(61))
        #expect(item.applePlayCount == 2)
    }

    @Test("Playlist fetches are shared within a minute and cached evidence cannot undo a reset")
    func playlistCacheAndReset() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (track, item) = try fixture(context)
        item.sourceMusicPlaylistIDs = ["p.tiktok"]
        var requests = 0
        let service = ApplePlayCountSyncService(fetchPlaylist: { _ in
            requests += 1
            return [playlistObservation(count: 10)]
        }, fetchLibrary: { _ in [] }, fetch: { _ in [] })
        _ = await service.refreshCurrentTrack(track.id, in: context)
        _ = await service.refresh(in: context)
        #expect(requests == 1)
        #expect(item.applePlayCount == 2)
        try PlaylistItemRepository.resetAllStats(in: context)
        _ = await service.refresh(in: context)
        #expect(requests == 1)
        #expect(item.applePlayCount == 0)
    }

    @Test("Playlist and library totals have separate baselines and do not add the same plays twice")
    func playlistThenLibrary() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (_, item) = try fixture(context)
        let now = Date.now
        func library(_ count: Int) -> MusicLibraryPlaybackObservation {
            var result = entry(count: count).observation
            result.aliases.append("123")
            return result
        }
        try ApplePlayCountSyncService.apply([playlistObservation(count: 10)], startedAt: now, in: context)
        try ApplePlayCountSyncService.apply([playlistObservation(count: 12), library(100)], startedAt: now, in: context)
        #expect(item.applePlayCount == 4)
        try ApplePlayCountSyncService.apply([playlistObservation(count: 13), library(103)], startedAt: now, in: context)
        #expect(item.applePlayCount == 5)
        try ApplePlayCountSyncService.apply([playlistObservation(count: 0), library(90)], startedAt: now, in: context)
        #expect(item.applePlayCount == 5)
    }

    @Test("Different devices and merged aliases join playlist/library evidence without duplicate credit")
    func playlistCloudMerge() throws {
        let origin = UUID()
        let now = Date.now
        var phone = ApplePlayCountState(initialCount: 1, originID: origin)
        phone.observe(musicItemID: "playlist-count:123", count: 10, at: now,
                      aliases: ["123"], isPlaylistCount: true)
        phone.observe(musicItemID: "playlist-count:123", count: 12, at: now,
                      aliases: ["123"], isPlaylistCount: true)
        var tablet = ApplePlayCountState(initialCount: 1, originID: UUID())
        tablet.observe(musicItemID: "i.found", count: 100, at: now, aliases: ["123", "i.found"])
        tablet.observe(musicItemID: "i.found", count: 103, at: now, aliases: ["123", "i.found"])
        var merged = try #require(ApplePlayCountState.joined([phone, tablet]))
        merged.advance()
        #expect(merged.count == 4)
        var reverse = try #require(ApplePlayCountState.joined([tablet, phone, tablet]))
        reverse.advance()
        #expect(reverse == merged)
        // An unrelated recording's increase remains additive after a merge.
        var other = ApplePlayCountState(initialCount: 1, originID: UUID())
        other.observe(musicItemID: "playlist-count:456", count: 20, at: now, aliases: ["456"], isPlaylistCount: true)
        other.observe(musicItemID: "playlist-count:456", count: 21, at: now, aliases: ["456"], isPlaylistCount: true)
        merged.merge(other)
        #expect(merged.count == 6)
        let restored = try JSONDecoder().decode(ApplePlayCountState.self, from: JSONEncoder().encode(merged))
        #expect(restored == merged)
    }
}
