import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Apple play counts")
struct ApplePlayCountTests {
    let date = Date(timeIntervalSince1970: 1_000)

    private func observation(_ id: String = "i.song", count: Int?, aliases: [String] = []) -> MusicLibraryPlaybackObservation {
        MusicLibraryPlaybackObservation(aliases: aliases + [id], snapshot:
            MusicLibraryPlaybackSnapshot(musicItemID: id, playCount: count, lastPlayedDate: nil))
    }

    private func fixture(_ context: ModelContext, libraryID: String = "i.song", plays: Int = 1) throws -> PlaylistItemRecord {
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let track = TrackRecord(catalogID: "123", libraryID: libraryID, title: "Song", artistName: "Artist")
        context.insert(track)
        let item = PlaylistItemRecord(playlistID: bucket.id, trackID: track.id, playthroughCount: plays)
        context.insert(item)
        try context.save()
        return item
    }

    @Test("First valid observation matches existing plays, then follows only Apple deltas", arguments: [0, 1, 12])
    func seedsExistingCount(plays: Int) throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = try fixture(context, plays: plays)
        try ApplePlayCountSyncService.apply([observation(count: 10)], startedAt: date, in: context)
        #expect(item.applePlayCount == plays)
        item.playthroughCount += 1
        try ApplePlayCountSyncService.apply([observation(count: 10)], startedAt: date, in: context)
        #expect(item.applePlayCount == plays)
        try ApplePlayCountSyncService.apply([observation(count: 13)], startedAt: date, in: context)
        #expect(item.applePlayCount == plays + 3)
        #expect(item.playthroughCount == plays + 1)
        try context.save()
        let fresh = ModelContext(container)
        #expect(try PlaylistItemRepository.item(id: item.id, in: fresh)?.applePlayCount == plays + 3)
    }

    @Test("Missing counts do not seed zero; the eventual valid count uses the then-current Overplay count")
    func missingThenValid() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = try fixture(context)
        try ApplePlayCountSyncService.apply([observation(count: nil)], startedAt: date, in: context)
        #expect(item.applePlayCount == nil)
        item.playthroughCount = 3
        try ApplePlayCountSyncService.apply([observation(count: 100)], startedAt: date, in: context)
        #expect(item.applePlayCount == 3)
        try ApplePlayCountSyncService.apply([observation(count: nil), observation(count: -1)], startedAt: date, in: context)
        #expect(item.applePlayCount == 3)
    }

    @Test("Aliases returned in different batches still seed exactly once at the newest value")
    func initialBatchAliases() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = try fixture(context)
        try ApplePlayCountSyncService.apply([observation(count: 10), observation(count: 12)], startedAt: date, in: context)
        #expect(item.applePlayCount == 1)
        #expect(item.applePlayCountState?.counters.first?.baseline == 12)
    }

    @Test("Repeated, aliased and lower observations never double count or decrease")
    func repeatedObservations() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = try fixture(context)
        try ApplePlayCountSyncService.apply([observation(count: 10, aliases: ["123"])], startedAt: date, in: context)
        let advanced = observation(count: 12, aliases: ["123"])
        try ApplePlayCountSyncService.apply([advanced, advanced], startedAt: date, in: context)
        #expect(item.applePlayCount == 3)
        #expect(item.applePlayCountState?.counters.count == 1)
        #expect(try ApplePlayCountSyncService.apply([advanced, observation(count: 8)], startedAt: date, in: context) == 0)
        #expect(item.applePlayCount == 3)
    }

    @Test("New library identities start at their own baseline without importing lifetime history")
    func separateCounter() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = try fixture(context)
        try ApplePlayCountSyncService.apply([observation(count: 10)], startedAt: date, in: context)
        let track = try #require(try TrackRecordRepository.track(id: item.trackID, in: context))
        track.identityAliases.append("i.second")
        try ApplePlayCountSyncService.apply([observation(count: 12), observation("i.second", count: 100)], startedAt: date, in: context)
        #expect(item.applePlayCount == 3)
        try ApplePlayCountSyncService.apply([observation("i.second", count: 102)], startedAt: date, in: context)
        #expect(item.applePlayCount == 5)
        #expect(item.applePlayCountState?.counters.count == 2)
    }

    @Test("Automatic alias merge deduplicates starting credits and shared Apple increases")
    func automaticMerge() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let first = try fixture(context, plays: 1)
        let second = try fixture(context, plays: 2)
        try ApplePlayCountSyncService.apply([observation(count: 10)], startedAt: date, in: context)
        try ApplePlayCountSyncService.apply([observation(count: 12)], startedAt: date, in: context)
        #expect(first.applePlayCount == 3 && second.applePlayCount == 4)
        let defaults = PlaybackTestDefaults()
        defer { defaults.cleanUp() }
        try await TrackIdentityMergeService.mergeDuplicates(in: context, defaults: defaults.defaults)
        let item = try #require(try PlaylistItemRepository.allItems(in: context).first)
        #expect(item.playthroughCount == 3)
        #expect(item.applePlayCount == 4) // Highest starting credit (2), plus two shared increases.
        try ApplePlayCountSyncService.apply([observation(count: 13)], startedAt: date, in: context)
        #expect(item.applePlayCount == 5)
    }

    @Test("Manual merge preserves separate counters and future alias refreshes")
    func manualMerge() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let first = try fixture(context, plays: 1)
        let second = try fixture(context, libraryID: "i.second", plays: 2)
        try ApplePlayCountSyncService.apply([observation(count: 10), observation("i.second", count: 20)], startedAt: date, in: context)
        try ApplePlayCountSyncService.apply([observation(count: 11), observation("i.second", count: 22)], startedAt: date, in: context)
        #expect(first.applePlayCount == 2 && second.applePlayCount == 4)
        let defaults = PlaybackTestDefaults()
        defer { defaults.cleanUp() }
        let result = try DuplicateTrackService.merge(DuplicateTrackService.candidates(in: context), destination: .triage,
                                                     in: context, defaults: defaults.defaults)
        let item = try #require(try PlaylistItemRepository.item(id: result.itemID, in: context))
        #expect(item.applePlayCount == 6)
        #expect(item.applePlayCountState?.counters.count == 2)
        try ApplePlayCountSyncService.apply([observation(count: 12), observation("i.second", count: 23)], startedAt: date, in: context)
        #expect(item.applePlayCount == 8)
    }

    @Test("Merging an uninitialized donor preserves its existing Overplay history")
    func uninitializedDonor() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let first = try fixture(context)
        try ApplePlayCountSyncService.apply([observation(count: 10)], startedAt: date, in: context)
        let second = try fixture(context, libraryID: "i.second", plays: 4)
        PlaylistItemRepository.mergeStats(from: second, into: first, adoptEvictionStateIfNewer: false)
        #expect(first.playthroughCount == 5)
        #expect(first.applePlayCount == 5)
    }

    @Test("Mixed-initialization aliases share credit before a floor is published", arguments: [false, true])
    func mixedInitializationMerge(reverse: Bool) throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let initialized = try fixture(context)
        try ApplePlayCountSyncService.apply([observation(count: 10)], startedAt: date, in: context)
        let unknown = try fixture(context, plays: 4)
        let unknownID = unknown.id
        let keeper = reverse ? unknown : initialized
        let donor = reverse ? initialized : unknown
        PlaylistItemRepository.mergeStats(from: donor, into: keeper, adoptEvictionStateIfNewer: false)
        context.delete(donor)
        try context.save()
        #expect(keeper.applePlayCount == 4)
        #expect(keeper.playthroughCount == 5)
        try ApplePlayCountSyncService.apply([observation(count: 10)], startedAt: date, in: context)
        #expect(keeper.applePlayCount == 4)
        var late = ApplePlayCountState(initialCount: 4, originID: unknownID)
        late.observe(musicItemID: "i.song", count: 10, at: date)
        context.insert(ApplePlayCountRecord(itemID: unknownID, state: late, deviceID: "late-device"))
        try context.save()
        try ApplePlayCountSyncService.apply([observation(count: 11)], startedAt: date, in: context)
        #expect(keeper.applePlayCount == 5)
    }

    @Test("Unknown donor identity defers credit until later aliases prove the counter", arguments: ["i.song", "i.other"])
    func deferredDonorCredit(counter: String) throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let keeper = try fixture(context)
        try ApplePlayCountSyncService.apply([observation(count: 10)], startedAt: date, in: context)
        let donor = try fixture(context, plays: 4)
        let donorTrack = try #require(try TrackRecordRepository.track(id: donor.trackID, in: context))
        donorTrack.libraryID = nil
        donorTrack.catalogID = "other-catalog"
        PlaylistItemRepository.mergeStats(from: donor, into: keeper, adoptEvictionStateIfNewer: false)
        context.delete(donor)
        try context.save()
        #expect(keeper.applePlayCount == 4)
        var found = observation(counter, count: 10, aliases: ["other-catalog"])
        found.matchedTrackID = keeper.trackID
        try ApplePlayCountSyncService.apply([found], startedAt: date, in: context)
        #expect(keeper.applePlayCount == (counter == "i.song" ? 4 : 5))
        try ApplePlayCountSyncService.apply([found], startedAt: date, in: context)
        #expect(keeper.applePlayCount == (counter == "i.song" ? 4 : 5))
    }

    @Test("Reset rebases the comparison and rejects a request started before reset")
    func resetCounts() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = try fixture(context)
        try ApplePlayCountSyncService.apply([observation(count: 10)], startedAt: date, in: context)
        try ApplePlayCountSyncService.apply([observation(count: 12)], startedAt: date, in: context)
        try PlaylistItemRepository.resetAllStats(in: context)
        #expect(item.applePlayCount == 0 && item.playthroughCount == 0)
        try ApplePlayCountSyncService.apply([observation(count: 13)], startedAt: date, in: context)
        #expect(item.applePlayCount == 0)
        try ApplePlayCountSyncService.apply([observation(count: 13)], startedAt: .now, in: context)
        #expect(item.applePlayCount == 1)
    }

    @Test("Retired tracks are refreshed and Apple activity protects them from cleanup")
    func refreshRetired() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = try fixture(context, plays: 0)
        item.evictedAt = date
        let service = ApplePlayCountSyncService(fetch: { ids in
            #expect(ids.contains("i.song"))
            return [observation(count: 10)]
        })
        #expect(await service.refresh(in: context) == 1)
        let next = ApplePlayCountSyncService(fetch: { _ in [observation(count: 11)] })
        #expect(await next.refresh(in: context) == 1)
        #expect(item.applePlayCount == 1)
        #expect(!TrackRetentionPolicy.shouldDelete(item))
    }

    @Test("Failed requests leave baselines and displayed counts unchanged")
    func failedRefresh() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = try fixture(context)
        try ApplePlayCountSyncService.apply([observation(count: 10)], startedAt: date, in: context)
        let before = item.applePlayCountState
        let service = ApplePlayCountSyncService(fetch: { _ in throw CancellationError() })
        #expect(await service.refresh(in: context) == 0)
        #expect(item.applePlayCountState == before)
    }

    @Test("Shared presentation carries both counts through playlist and playback snapshots")
    func presentation() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = try fixture(context)
        try ApplePlayCountSyncService.apply([observation(count: 10)], startedAt: date, in: context)
        let track = try #require(try TrackRecordRepository.track(id: item.trackID, in: context))
        let playlist = try #require(try PlaylistRepository.playlist(id: item.playlistID, in: context))
        let rows = PlaylistPresentationBuilder(playlists: [playlist], items: [item], tracks: [track])
            .trackSummaries(forPlaylistID: playlist.id)
        #expect(rows.first?.playSkipMetricLabel == "1/1 plays · 0 skips")
        #expect(CurrentPlaybackTrack(track, musicItemID: "i.song", item: item).applePlayCount == 1)
        #expect(PlayCountPresentation.metric(overplay: 2, apple: nil, skips: 1) == "2/— plays · 1 skip")
    }

    @Test("A save failure restores only count changes and can be retried")
    func failedSave() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = try fixture(context)
        item.skipCount = 7
        let service = ApplePlayCountSyncService(saveChanges: { _ in throw CancellationError() }, fetch: { _ in
            [observation(count: 10)]
        })
        #expect(await service.refresh(in: context) == 0)
        #expect(item.applePlayCount == nil)
        #expect(item.skipCount == 7)
        let retry = ApplePlayCountSyncService(fetch: { _ in [observation(count: 12)] })
        #expect(await retry.refresh(in: context) == 1)
        #expect(item.applePlayCount == 1)
    }

    @Test("Refresh publishes fresh counts across contexts to Now Playing and CarPlay")
    func crossSurfaceRefresh() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let item = try fixture(context)
        let track = try #require(try TrackRecordRepository.track(id: item.trackID, in: context))
        let playlist = try #require(try PlaylistRepository.playlist(id: item.playlistID, in: context))
        let defaults = PlaybackTestDefaults()
        defer { defaults.cleanUp() }
        let controller = PlaybackController(localPlaybackDefaults: defaults.defaults)
        controller.currentPlaylistID = playlist.musicPlaylistID
        controller.currentPlaylistItem = item
        controller.currentTrack = CurrentPlaybackTrack(track, musicItemID: "i.song", item: item)
        controller.activePlaylistSnapshot = ActivePlaylistSnapshot(
            playlist: playlist, items: [item], tracks: [track],
            playbackOrderState: PlaybackOrderState(playerID: controller.playerID, musicPlaylistID: playlist.musicPlaylistID)
        )
        let otherContext = ModelContext(container)
        let service = ApplePlayCountSyncService(fetch: { _ in [observation(count: 10)] })
        #expect(await service.refresh(in: otherContext, playbackController: controller) == 1)
        #expect(controller.displayedApplePlayCount == 1)
        #expect(controller.currentTrack?.applePlayCount == 1)
        let snapshot = try #require(controller.activePlaylistSnapshot)
        #expect(snapshot.rows.first?.applePlayCount == 1)
        #expect(CarPlayLibrarySnapshot.trackSummaries(from: snapshot).first?.applePlayCount == 1)
        let presentation = NowPlayingPresentationFactory.presentation(playbackController: controller, settings: OverplaySettings())
        #expect(presentation.playSkipMetricText == "1/1 plays · 0 skips")
    }
}
