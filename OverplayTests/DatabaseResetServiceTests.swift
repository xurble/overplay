import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Database reset service")
struct DatabaseResetServiceTests {
    @Test("nuke database deletes persisted app data and recreates default settings")
    func nukeDatabaseDeletesPersistedAppDataAndRecreatesDefaultSettings() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Glasshouse",
            artistName: "The Sample Set"
        )

        context.insert(OverplaySettings(
            selectedPlaylistID: "playlist-1",
            selectedPlaylistName: "Main"
        ))
        context.insert(playlist)
        context.insert(track)
        context.insert(PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 2
        ))
        context.insert(HistoryEvent(
            playlistID: playlist.id,
            trackID: track.id,
            eventType: .trackAdded,
            source: .user
        ))
        try context.save()

        let settings = try DatabaseResetService.nukeDatabase(in: context)

        #expect(settings.selectedPlaylistID == nil)
        #expect(settings.selectedPlaylistName == nil)
        #expect(try context.fetch(FetchDescriptor<OverplaySettings>()).count == 1)
        #expect(try PlaylistRepository.allPlaylists(in: context).isEmpty)
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
        #expect(try PlaylistItemRepository.allItems(in: context).isEmpty)
        #expect(try context.fetch(FetchDescriptor<HistoryEvent>()).isEmpty)
    }
}
