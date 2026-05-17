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
            durationSeconds: 180
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
}
