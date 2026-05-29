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

    @Test("legacy tracked tracks reset persisted data")
    func legacyTrackedTracksResetPersistedData() throws {
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
            artistName: "The Sample Set"
        ))
        context.insert(PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        ))
        context.insert(TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Glasshouse",
            artistName: "The Sample Set"
        ))

        try LegacyModelMigration.migrate(in: context)

        #expect(try context.fetch(FetchDescriptor<OverplaySettings>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TrackedTrack>()).isEmpty)
        #expect(try PlaylistRepository.allPlaylists(in: context).isEmpty)
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
    }

    @Test("legacy selected playlist without new records resets settings")
    func legacySelectedPlaylistWithoutNewRecordsResetsSettings() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        context.insert(OverplaySettings(
            selectedPlaylistID: "playlist-1",
            selectedPlaylistName: "Main"
        ))

        try LegacyModelMigration.migrate(in: context)

        #expect(try context.fetch(FetchDescriptor<OverplaySettings>()).isEmpty)
    }

    @Test("new model data without legacy tracks is preserved")
    func newModelDataWithoutLegacyTracksIsPreserved() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        context.insert(OverplaySettings(
            selectedPlaylistID: "playlist-1",
            selectedPlaylistName: "Main"
        ))
        context.insert(PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        ))

        try LegacyModelMigration.migrate(in: context)

        #expect(try context.fetch(FetchDescriptor<OverplaySettings>()).count == 1)
        #expect(try PlaylistRepository.allPlaylists(in: context).count == 1)
    }
}
