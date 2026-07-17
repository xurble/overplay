import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
struct CarPlayLibrarySnapshotTests {
    @Test func playlistSummariesIncludeActivePlayablePlaylistsInCarPlayOrder() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = ModelContext(container)

        let oneTrue = PlaylistRecord(musicPlaylistID: "one", name: "Keepers", role: .oneTruePlaylist)
        let triage = PlaylistRecord(musicPlaylistID: "triage", name: "Inbox", role: .triage)
        let inactive = PlaylistRecord(musicPlaylistID: "inactive", name: "Old", role: .triage, isActive: false)
        context.insert(oneTrue)
        context.insert(triage)
        context.insert(inactive)

        let playableTrack = TrackRecord(title: "A", artistName: "Artist")
        let evictedTrack = TrackRecord(title: "B", artistName: "Artist")
        let inactiveTrack = TrackRecord(title: "C", artistName: "Artist")
        context.insert(playableTrack)
        context.insert(evictedTrack)
        context.insert(inactiveTrack)

        context.insert(PlaylistItemRecord(playlistID: oneTrue.id, trackID: playableTrack.id))
        context.insert(PlaylistItemRecord(playlistID: oneTrue.id, trackID: evictedTrack.id, evictedAt: .now))
        context.insert(PlaylistItemRecord(playlistID: inactive.id, trackID: inactiveTrack.id))
        try context.save()

        let summaries = try CarPlayLibrarySnapshot.playlistSummaries(in: context)
        let sharedSummaries = PlaylistPresentationBuilder(
            playlists: [oneTrue, triage],
            items: try PlaylistItemRepository.allItems(in: context),
            tracks: [playableTrack, evictedTrack, inactiveTrack],
        )
        .activePlaylistSummaries()

        #expect(summaries.map(\.title) == ["Keepers", "Inbox"])
        #expect(summaries == sharedSummaries)
        #expect(summaries.first?.role == .oneTruePlaylist)
        #expect(summaries.first?.playableTrackCount == 1)
        #expect(summaries.last?.playableTrackCount == 0)
    }

    @Test func trackSummariesIncludePlayableTracksInCreatedOrder() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = ModelContext(container)

        let playlist = PlaylistRecord(musicPlaylistID: "one", name: "Overplay", role: .oneTruePlaylist)
        context.insert(playlist)

        let firstTrack = TrackRecord(title: "Mr Brightside", artistName: "The Killers")
        let secondTrack = TrackRecord(title: "Somebody Told Me", artistName: "The Killers")
        let evictedTrack = TrackRecord(title: "Smile Like You Mean It", artistName: "The Killers")
        context.insert(firstTrack)
        context.insert(secondTrack)
        context.insert(evictedTrack)

        context.insert(PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: secondTrack.id,
            sortOrder: 2,
            skipCount: 2,
            createdAt: Date(timeIntervalSince1970: 20)
        ))
        context.insert(PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: firstTrack.id,
            sortOrder: 1,
            createdAt: Date(timeIntervalSince1970: 10)
        ))
        context.insert(PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: evictedTrack.id,
            sortOrder: 3,
            evictedAt: .now,
            createdAt: Date(timeIntervalSince1970: 30)
        ))
        try context.save()

        let tracks = try CarPlayLibrarySnapshot.trackSummaries(
            forPlaylistID: playlist.id,
            in: context
        )
        let sharedTracks = PlaylistPresentationBuilder(
            playlists: [playlist],
            items: try PlaylistItemRepository.playableItems(forPlaylistID: playlist.id, in: context),
            tracks: [firstTrack, secondTrack, evictedTrack],
        )
        .trackSummaries(forPlaylistID: playlist.id)

        #expect(tracks.map(\.title) == ["Mr Brightside", "Somebody Told Me"])
        #expect(tracks == sharedTracks)
        #expect(tracks.first?.detailText == "The Killers - 0 plays / 0 skips")
        #expect(tracks.last?.detailText == "The Killers - 0 plays / 2 skips")
    }

    @Test func trackSummariesFollowStoredShuffleOrder() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = ModelContext(container)

        let playlist = PlaylistRecord(musicPlaylistID: "one", name: "Overplay", role: .oneTruePlaylist)
        context.insert(playlist)

        let firstTrack = TrackRecord(title: "First", artistName: "Artist")
        let secondTrack = TrackRecord(title: "Second", artistName: "Artist")
        let thirdTrack = TrackRecord(title: "Third", artistName: "Artist")
        context.insert(firstTrack)
        context.insert(secondTrack)
        context.insert(thirdTrack)

        context.insert(PlaylistItemRecord(playlistID: playlist.id, trackID: firstTrack.id, sortOrder: 1))
        context.insert(PlaylistItemRecord(playlistID: playlist.id, trackID: secondTrack.id, sortOrder: 2))
        context.insert(PlaylistItemRecord(playlistID: playlist.id, trackID: thirdTrack.id, sortOrder: 3))
        try context.save()

        let tracks = try CarPlayLibrarySnapshot.trackSummaries(
            forPlaylistID: playlist.id,
            playbackOrderState: PlaybackOrderState(
                playerID: "main",
                musicPlaylistID: playlist.musicPlaylistID,
                orderedTrackIDs: [
                    thirdTrack.id.uuidString,
                    firstTrack.id.uuidString,
                    secondTrack.id.uuidString
                ]
            ),
            in: context
        )

        #expect(tracks.map(\.title) == ["Third", "First", "Second"])
    }
}
