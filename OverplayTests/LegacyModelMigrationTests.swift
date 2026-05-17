import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Legacy model migration")
struct LegacyModelMigrationTests {
    @Test("empty legacy data does not create new records")
    func emptyLegacyDataDoesNotCreateNewRecords() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        try LegacyModelMigration.migrate(in: context)

        #expect(try context.fetch(FetchDescriptor<OverplaySettings>()).isEmpty)
        #expect(try PlaylistRepository.allPlaylists(in: context).isEmpty)
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
        #expect(try PlaylistItemRepository.allItems(in: context).isEmpty)
    }

    @Test("selected playlist and tracked track migrate into new records")
    func selectedPlaylistAndTrackedTrackMigrateIntoNewRecords() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let createdAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 200)
        let evictedAt = Date(timeIntervalSince1970: 300)
        let lastSkippedAt = Date(timeIntervalSince1970: 250)

        context.insert(OverplaySettings(
            selectedPlaylistID: "playlist-1",
            selectedPlaylistName: "Main",
            evictAfterSkips: 3
        ))
        context.insert(TrackedTrack(
            id: "track-1",
            catalogID: "catalog-1",
            libraryID: "library-1",
            playlistEntryID: "entry-1",
            playlistID: "playlist-1",
            title: "Glasshouse",
            artistName: "The Sample Set",
            albumTitle: "Overplay Sessions",
            durationSeconds: 214,
            skipCount: 3,
            playthroughCount: 2,
            lastSkippedAt: lastSkippedAt,
            evictedAt: evictedAt,
            evictionReason: "3 skips before 50%",
            protected: true,
            lastSeenInPlaylistAt: updatedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        ))

        try LegacyModelMigration.migrate(in: context)

        let migratedPlaylist = try PlaylistRepository.oneTruePlaylist(in: context)
        let migratedTrack = try TrackRecordRepository.allTracks(in: context).first
        let playlist = try #require(migratedPlaylist)
        let track = try #require(migratedTrack)
        let migratedItem = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context).first
        let item = try #require(migratedItem)

        #expect(playlist.musicPlaylistID == "playlist-1")
        #expect(playlist.name == "Main")
        #expect(playlist.role == .oneTruePlaylist)
        #expect(track.catalogID == "catalog-1")
        #expect(track.libraryID == "library-1")
        #expect(track.title == "Glasshouse")
        #expect(item.playlistID == playlist.id)
        #expect(item.trackID == track.id)
        #expect(item.musicPlaylistEntryID == "entry-1")
        #expect(item.skipCount == 3)
        #expect(item.playthroughCount == 2)
        #expect(item.lastSkippedAt == lastSkippedAt)
        #expect(item.lastSeenInPlaylistAt == updatedAt)
        #expect(item.evictedAt == evictedAt)
        #expect(item.evictionReason == .skipCount)
        #expect(item.evictionSource == .playbackRule)
        #expect(item.protected)
        #expect(item.createdAt == createdAt)
        #expect(item.updatedAt == updatedAt)
    }

    @Test("migration is idempotent")
    func migrationIsIdempotent() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        context.insert(OverplaySettings(
            selectedPlaylistID: "playlist-1",
            selectedPlaylistName: "Main"
        ))
        context.insert(TrackedTrack(
            id: "track-1",
            playlistID: "playlist-1",
            title: "Glasshouse",
            artistName: "The Sample Set",
            skipCount: 1,
            playthroughCount: 4
        ))

        try LegacyModelMigration.migrate(in: context)
        try LegacyModelMigration.migrate(in: context)

        let playlists = try PlaylistRepository.allPlaylists(in: context)
        let tracks = try TrackRecordRepository.allTracks(in: context)
        let items = try PlaylistItemRepository.allItems(in: context)

        #expect(playlists.count == 1)
        #expect(tracks.count == 1)
        #expect(items.count == 1)
        #expect(items.first?.skipCount == 1)
        #expect(items.first?.playthroughCount == 4)
    }
}
