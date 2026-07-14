import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Track identity merge service")
struct TrackIdentityMergeServiceTests {
    @Test("records sharing an identifier collapse into the oldest record")
    func recordsSharingAnIdentifierCollapseIntoTheOldestRecord() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let canonical = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            musicKitPlaybackData: Data("cached-playback".utf8),
            createdAt: Date(timeIntervalSince1970: 20)
        )
        context.insert(canonical)
        context.insert(duplicate)
        let duplicateID = duplicate.id

        let summary = try TrackIdentityMergeService.mergeDuplicates(in: context)
        let tracks = try TrackRecordRepository.allTracks(in: context)

        #expect(summary.mergedTrackCount == 1)
        #expect(summary.localTrackIDMapping == [duplicateID.uuidString: canonical.id.uuidString])
        #expect(tracks.count == 1)
        #expect(tracks.first?.id == canonical.id)
        #expect(canonical.catalogID == "1440833098")
        #expect(canonical.libraryID == "i.abc123")
        #expect(canonical.musicKitPlaybackData == Data("cached-playback".utf8))
    }

    @Test("a genuine catalog ID heals a legacy mirrored catalog field")
    func aGenuineCatalogIDHealsALegacyMirroredCatalogField() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let legacyMirrored = TrackRecord(
            catalogID: "i.abc123",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let wellFormed = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        context.insert(legacyMirrored)
        context.insert(wellFormed)

        try TrackIdentityMergeService.mergeDuplicates(in: context)
        let tracks = try TrackRecordRepository.allTracks(in: context)

        #expect(tracks.count == 1)
        #expect(tracks.first?.id == legacyMirrored.id)
        #expect(legacyMirrored.catalogID == "1440833098")
        #expect(legacyMirrored.libraryID == "i.abc123")
    }

    @Test("playlist items repoint to the canonical track and merge stats")
    func playlistItemsRepointToTheCanonicalTrackAndMergeStats() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let canonical = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let canonicalItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: canonical.id,
            skipCount: 3,
            playthroughCount: 2,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let duplicateItem = PlaylistItemRecord(
            playlistID: playlistID,
            trackID: duplicate.id,
            skipCount: 2,
            playthroughCount: 1,
            lastPlayedAt: Date(timeIntervalSince1970: 300),
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(canonicalItem)
        context.insert(duplicateItem)

        let summary = try TrackIdentityMergeService.mergeDuplicates(in: context)
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)

        #expect(summary.mergedTrackCount == 1)
        #expect(summary.mergedItemCount == 1)
        #expect(items.count == 1)
        #expect(items.first?.id == canonicalItem.id)
        #expect(canonicalItem.trackID == canonical.id)
        #expect(canonicalItem.skipCount == 5)
        #expect(canonicalItem.playthroughCount == 3)
        #expect(canonicalItem.lastPlayedAt == Date(timeIntervalSince1970: 300))
    }

    @Test("items in different playlists stay separate after repointing")
    func itemsInDifferentPlaylistsStaySeparateAfterRepointing() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let firstPlaylistID = UUID()
        let secondPlaylistID = UUID()
        let canonical = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let firstItem = PlaylistItemRecord(
            playlistID: firstPlaylistID,
            trackID: canonical.id,
            skipCount: 3
        )
        let secondItem = PlaylistItemRecord(
            playlistID: secondPlaylistID,
            trackID: duplicate.id,
            skipCount: 2
        )
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(firstItem)
        context.insert(secondItem)

        let summary = try TrackIdentityMergeService.mergeDuplicates(in: context)

        #expect(summary.mergedTrackCount == 1)
        #expect(summary.mergedItemCount == 0)
        #expect(firstItem.skipCount == 3)
        #expect(secondItem.skipCount == 2)
        #expect(secondItem.trackID == canonical.id)
    }

    @Test("history events repoint to the canonical track")
    func historyEventsRepointToTheCanonicalTrack() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let canonical = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let event = HistoryEvent(
            trackID: duplicate.id,
            eventType: .skipCounted,
            source: .playback
        )
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(event)

        try TrackIdentityMergeService.mergeDuplicates(in: context)

        #expect(event.trackID == canonical.id)
    }

    @Test("device-local stores rekey merged local track IDs")
    func deviceLocalStoresRekeyMergedLocalTrackIDs() throws {
        let suiteName = "OverplayTests.TrackIdentityMerge.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let canonical = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let unrelatedTrackID = UUID().uuidString
        context.insert(canonical)
        context.insert(duplicate)

        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: "main",
                musicPlaylistID: "playlist-1",
                orderedTrackIDs: [duplicate.id.uuidString, canonical.id.uuidString, unrelatedTrackID]
            ),
            to: defaults
        )
        PlaybackIdentityStore.recordAlias(
            "runtime-1",
            playerID: "main",
            musicPlaylistID: "playlist-1",
            localTrackID: duplicate.id.uuidString,
            to: defaults
        )
        LocalPlaybackStateStore.save(
            LocalPlaybackState(
                playlistID: "playlist-1",
                musicItemID: "i.abc123",
                elapsedSeconds: 10,
                wasPlaying: false,
                updatedAt: .now,
                localTrackID: duplicate.id.uuidString
            ),
            to: defaults
        )

        try TrackIdentityMergeService.mergeDuplicates(in: context, defaults: defaults)

        let orderState = PlaybackOrderStore.state(playerID: "main", musicPlaylistID: "playlist-1", from: defaults)
        #expect(orderState.orderedTrackIDs == [canonical.id.uuidString, unrelatedTrackID])
        #expect(PlaybackIdentityStore.aliases(
            playerID: "main",
            musicPlaylistID: "playlist-1",
            localTrackID: canonical.id.uuidString,
            from: defaults
        ) == ["runtime-1"])
        #expect(LocalPlaybackStateStore.load(from: defaults)?.localTrackID == canonical.id.uuidString)
    }

    @Test("merge is idempotent")
    func mergeIsIdempotent() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let canonical = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let duplicate = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        context.insert(canonical)
        context.insert(duplicate)
        context.insert(PlaylistItemRecord(playlistID: playlistID, trackID: canonical.id, skipCount: 1))
        context.insert(PlaylistItemRecord(playlistID: playlistID, trackID: duplicate.id, skipCount: 2))

        let firstSummary = try TrackIdentityMergeService.mergeDuplicates(in: context)
        let secondSummary = try TrackIdentityMergeService.mergeDuplicates(in: context)
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)

        #expect(firstSummary.didChange)
        #expect(secondSummary == TrackIdentityMergeService.MergeSummary())
        #expect(items.count == 1)
        #expect(items.first?.skipCount == 3)
    }

    @Test("distinct songs are untouched")
    func distinctSongsAreUntouched() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        context.insert(TrackRecord(catalogID: "111", title: "One", artistName: "Artist"))
        context.insert(TrackRecord(catalogID: "222", libraryID: "i.two", title: "Two", artistName: "Artist"))
        context.insert(TrackRecord(libraryID: "i.three", title: "Three", artistName: "Artist"))

        let summary = try TrackIdentityMergeService.mergeDuplicates(in: context)

        #expect(summary == TrackIdentityMergeService.MergeSummary())
        #expect(try TrackRecordRepository.allTracks(in: context).count == 3)
    }

    @Test("transitive identifier chains merge into one record")
    func transitiveIdentifierChainsMergeIntoOneRecord() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let first = TrackRecord(
            catalogID: "1440833098",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let second = TrackRecord(
            catalogID: "1440833098",
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let third = TrackRecord(
            libraryID: "i.abc123",
            title: "Song",
            artistName: "Artist",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        context.insert(first)
        context.insert(second)
        context.insert(third)

        let summary = try TrackIdentityMergeService.mergeDuplicates(in: context)
        let tracks = try TrackRecordRepository.allTracks(in: context)

        #expect(summary.mergedTrackCount == 2)
        #expect(tracks.count == 1)
        #expect(tracks.first?.id == first.id)
    }
}
