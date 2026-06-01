import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("New SwiftData models")
struct NewSwiftDataModelTests {
    @Test("playlist track item and history records persist together")
    func playlistTrackItemAndHistoryRecordsPersistTogether() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlistID = UUID()
        let trackID = UUID()

        context.insert(PlaylistRecord(
            id: playlistID,
            musicPlaylistID: "apple-playlist-1",
            name: "One True Playlist",
            role: .oneTruePlaylist,
            lastSyncedAt: .now
        ))
        context.insert(TrackRecord(
            id: trackID,
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Glasshouse",
            artistName: "The Sample Set",
            albumTitle: "Overplay Sessions",
            artworkURLTemplate: "https://example.com/artwork.jpg",
            durationSeconds: 214
        ))
        context.insert(PlaylistItemRecord(
            playlistID: playlistID,
            trackID: trackID,
            musicPlaylistEntryID: "entry-1",
            skipCount: 3,
            playthroughCount: 1,
            evictedAt: .now,
            evictionReason: .skipCount,
            evictionSource: .playbackRule
        ))
        context.insert(HistoryEvent(
            playlistID: playlistID,
            trackID: trackID,
            eventType: .evicted,
            source: .playback,
            skipCountAtEvent: 3,
            remoteMutationStatus: .pending,
            message: "3 skips before 50%"
        ))
        try context.save()

        let playlists = try context.fetch(FetchDescriptor<PlaylistRecord>())
        let tracks = try context.fetch(FetchDescriptor<TrackRecord>())
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>())
        let events = try context.fetch(FetchDescriptor<HistoryEvent>())

        #expect(playlists.count == 1)
        #expect(playlists.first?.role == .oneTruePlaylist)
        #expect(tracks.count == 1)
        #expect(tracks.first?.catalogID == "catalog-1")
        #expect(items.count == 1)
        #expect(items.first?.playlistID == playlistID)
        #expect(items.first?.trackID == trackID)
        #expect(items.first?.evictionReason == .skipCount)
        #expect(items.first?.evictionSource == .playbackRule)
        #expect(items.first?.isPlayable == false)
        #expect(events.count == 1)
        #expect(events.first?.eventType == .evicted)
        #expect(events.first?.source == .playback)
        #expect(events.first?.remoteMutationStatus == .pending)
    }

    @Test("playlist item playability excludes evictions and remote removals")
    func playlistItemPlayabilityExcludesEvictionsAndRemoteRemovals() {
        let playlistID = UUID()
        let trackID = UUID()

        let activeItem = PlaylistItemRecord(playlistID: playlistID, trackID: trackID)
        let evictedItem = PlaylistItemRecord(playlistID: playlistID, trackID: trackID, evictedAt: .now)
        let removedItem = PlaylistItemRecord(playlistID: playlistID, trackID: trackID, removedFromRemoteAt: .now)

        #expect(activeItem.isPlayable)
        #expect(!evictedItem.isPlayable)
        #expect(!removedItem.isPlayable)
    }
}
