import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("New model repositories")
struct NewModelRepositoryTests {
    @Test("playlist upsert creates then updates by Apple Music ID")
    func playlistUpsertCreatesThenUpdatesByAppleMusicID() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let inserted = try PlaylistRepository.upsert(
            musicPlaylistID: "playlist-1",
            name: "Original",
            role: .triage,
            in: context
        )
        let updated = try PlaylistRepository.upsert(
            musicPlaylistID: "playlist-1",
            name: "One True Playlist",
            role: .oneTruePlaylist,
            in: context
        )
        let playlists = try PlaylistRepository.allPlaylists(in: context)

        #expect(playlists.count == 1)
        #expect(inserted.id == updated.id)
        #expect(updated.name == "One True Playlist")
        #expect(updated.role == .oneTruePlaylist)
    }

    @Test("setting one true playlist demotes previous one true playlist")
    func settingOneTruePlaylistDemotesPreviousOneTruePlaylist() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        try PlaylistRepository.setOneTruePlaylist(
            AppleMusicPlaylist(id: "playlist-1", name: "First", trackCount: 10),
            in: context
        )
        let selected = try PlaylistRepository.setOneTruePlaylist(
            AppleMusicPlaylist(id: "playlist-2", name: "Second", trackCount: 12),
            in: context
        )
        let playlists = try PlaylistRepository.allPlaylists(in: context)

        #expect(selected.musicPlaylistID == "playlist-2")
        #expect(playlists.count == 2)
        #expect(playlists.filter { $0.role == .oneTruePlaylist }.count == 1)
        let firstPlaylist = try PlaylistRepository.playlist(musicPlaylistID: "playlist-1", in: context)
        #expect(firstPlaylist?.role == .triage)
    }

    @Test("adding triage playlist does not change existing one true playlist")
    func addingTriagePlaylistDoesNotChangeExistingOneTruePlaylist() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        try SettingsRepository.selectPlaylist(
            AppleMusicPlaylist(id: "playlist-1", name: "Main", trackCount: 10),
            in: context
        )
        try PlaylistRepository.addTriagePlaylist(
            AppleMusicPlaylist(id: "playlist-2", name: "Triage", trackCount: 12),
            in: context
        )
        let settings = try SettingsRepository.settings(in: context)
        let fetchedOneTruePlaylist = try PlaylistRepository.oneTruePlaylist(in: context)
        let oneTruePlaylist = try #require(fetchedOneTruePlaylist)

        #expect(settings.selectedPlaylistID == "playlist-1")
        #expect(oneTruePlaylist.musicPlaylistID == "playlist-1")
        let triagePlaylist = try PlaylistRepository.playlist(musicPlaylistID: "playlist-2", in: context)
        #expect(triagePlaylist?.role == .triage)
    }

    @Test("deactivating triage playlist hides it from active playlists")
    func deactivatingTriagePlaylistHidesItFromActivePlaylists() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let playlist = try PlaylistRepository.addTriagePlaylist(
            AppleMusicPlaylist(id: "playlist-2", name: "Triage", trackCount: 12),
            in: context
        )
        try PlaylistRepository.deactivateTriagePlaylist(playlist, in: context)
        let activePlaylists = try PlaylistRepository.activePlaylists(in: context)
        let fetchedPlaylist = try PlaylistRepository.playlist(musicPlaylistID: "playlist-2", in: context)

        #expect(activePlaylists.isEmpty)
        #expect(fetchedPlaylist?.isActive == false)
    }

    @Test("track record upsert creates then updates without changing identity")
    func trackRecordUpsertCreatesThenUpdatesWithoutChangingIdentity() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext

        let firstSnapshot = TrackSnapshot(
            id: "track-1",
            catalogID: "catalog-1",
            libraryID: "library-1",
            playlistEntryID: "entry-1",
            playlistID: "playlist-1",
            title: "Original",
            artistName: "Sample Artist",
            albumTitle: "Original Album",
            artworkURLTemplate: nil,
            durationSeconds: 180,
            musicKitPlaybackData: Data("cached-playback".utf8)
        )
        let inserted = try TrackRecordRepository.upsert(firstSnapshot, in: context)

        let secondSnapshot = TrackSnapshot(
            id: "track-1",
            catalogID: "catalog-1",
            libraryID: "library-1",
            playlistEntryID: "entry-2",
            playlistID: "playlist-1",
            title: "Updated",
            artistName: "Sample Artist",
            albumTitle: "Updated Album",
            artworkURLTemplate: "https://example.com/artwork.jpg",
            durationSeconds: 210
        )
        let updated = try TrackRecordRepository.upsert(secondSnapshot, in: context)
        let tracks = try TrackRecordRepository.allTracks(in: context)

        #expect(tracks.count == 1)
        #expect(inserted.id == updated.id)
        #expect(updated.title == "Updated")
        #expect(updated.albumTitle == "Updated Album")
        #expect(updated.durationSeconds == 210)
        #expect(updated.musicKitPlaybackData == Data("cached-playback".utf8))
    }

    @Test("playlist item upsert creates then updates membership by playlist and track")
    func playlistItemUpsertCreatesThenUpdatesMembershipByPlaylistAndTrack() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let trackID = UUID()

        let inserted = try PlaylistItemRepository.upsert(
            playlistID: playlistID,
            trackID: trackID,
            musicPlaylistEntryID: "entry-1",
            in: context
        )
        inserted.skipCount = 2

        let updated = try PlaylistItemRepository.upsert(
            playlistID: playlistID,
            trackID: trackID,
            musicPlaylistEntryID: "entry-2",
            in: context
        )
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)

        #expect(items.count == 1)
        #expect(inserted.id == updated.id)
        #expect(updated.musicPlaylistEntryID == "entry-2")
        #expect(updated.skipCount == 2)
    }

    @Test("playlist items are returned in synced playlist order")
    func playlistItemsAreReturnedInSyncedPlaylistOrder() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()

        let last = try PlaylistItemRepository.upsert(
            playlistID: playlistID,
            trackID: UUID(),
            musicPlaylistEntryID: "entry-last",
            sortOrder: 2,
            in: context
        )
        let first = try PlaylistItemRepository.upsert(
            playlistID: playlistID,
            trackID: UUID(),
            musicPlaylistEntryID: "entry-first",
            sortOrder: 0,
            in: context
        )
        let middle = try PlaylistItemRepository.upsert(
            playlistID: playlistID,
            trackID: UUID(),
            musicPlaylistEntryID: "entry-middle",
            sortOrder: 1,
            in: context
        )

        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)

        #expect(items.map(\.id) == [first.id, middle.id, last.id])
    }

    @Test("event repository writes history events")
    func eventRepositoryWritesHistoryEvents() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let trackID = UUID()

        let event = EventRepository.logHistory(
            playlistID: playlistID,
            trackID: trackID,
            eventType: .promoted,
            source: .user,
            remoteMutationStatus: .succeeded,
            message: "Promoted from triage",
            in: context
        )
        try context.save()

        let events = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(events.count == 1)
        #expect(events.first?.id == event.id)
        #expect(events.first?.playlistID == playlistID)
        #expect(events.first?.trackID == trackID)
        #expect(events.first?.eventType == .promoted)
        #expect(events.first?.source == .user)
        #expect(events.first?.remoteMutationStatus == .succeeded)
    }

    @Test("triage playlist playback uses linked playlist state")
    func triagePlaylistPlaybackUsesLinkedPlaylistState() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let controller = PlaybackController()
        let settings = OverplaySettings(
            selectedPlaylistID: "playlist-1",
            selectedPlaylistName: "Main"
        )
        let triagePlaylist = PlaylistRecord(
            musicPlaylistID: "playlist-2",
            name: "Triage",
            role: .triage
        )
        context.insert(settings)
        context.insert(triagePlaylist)

        await controller.playPlaylist(triagePlaylist, settings: settings, context: context)

        #expect(controller.currentPlaylistID == nil)
        #expect(controller.statusMessage == "No playable tracks remain after local evictions.")
    }
}
