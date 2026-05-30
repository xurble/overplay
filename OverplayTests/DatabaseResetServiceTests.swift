import Foundation
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
        context.insert(SettingsRecord(syncOnForeground: false))
        context.insert(TrackedTrack(
            id: "legacy-track-1",
            playlistID: "playlist-1",
            title: "Legacy",
            artistName: "The Sample Set"
        ))
        context.insert(PlaybackEvent(trackID: "legacy-track-1", eventType: "started"))
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
        #expect(try context.fetch(FetchDescriptor<SettingsRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TrackedTrack>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaybackEvent>()).isEmpty)
        #expect(try PlaylistRepository.allPlaylists(in: context).isEmpty)
        #expect(try TrackRecordRepository.allTracks(in: context).isEmpty)
        #expect(try PlaylistItemRepository.allItems(in: context).isEmpty)
        #expect(try context.fetch(FetchDescriptor<HistoryEvent>()).isEmpty)
    }
}
