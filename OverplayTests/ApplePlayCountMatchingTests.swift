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
}
