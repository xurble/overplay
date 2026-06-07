import Foundation
import Testing
@testable import Overplay

@MainActor
@Suite("Playback queue builder")
struct PlaybackQueueBuilderTests {
    @Test("queue identifiers include only playable playlist items")
    func queueIdentifiersIncludeOnlyPlayablePlaylistItems() {
        let playlistID = UUID()
        let activeTrackID = UUID()
        let evictedTrackID = UUID()
        let orphanTrackID = UUID()
        let tracksByID = [
            activeTrackID: TrackRecord(
                catalogID: "catalog-active",
                libraryID: "library-active",
                title: "Active",
                artistName: "Sample Artist"
            ),
            evictedTrackID: TrackRecord(
                catalogID: "catalog-evicted",
                libraryID: "library-evicted",
                title: "Evicted",
                artistName: "Sample Artist"
            ),
        ]
        let items = [
            PlaylistItemRecord(playlistID: playlistID, trackID: activeTrackID),
            PlaylistItemRecord(playlistID: playlistID, trackID: evictedTrackID, evictedAt: .now),
            PlaylistItemRecord(playlistID: playlistID, trackID: orphanTrackID)
        ]

        let identifiers = PlaybackQueueBuilder.playableMusicItemIDs(
            items: items,
            tracksByID: tracksByID
        )

        #expect(identifiers == Set(["catalog-active", "library-active"]))
    }

    @Test("playlist item can be matched by catalog or library identifier")
    func playlistItemCanBeMatchedByCatalogOrLibraryIdentifier() throws {
        let playlistID = UUID()
        let trackID = UUID()
        let item = PlaylistItemRecord(playlistID: playlistID, trackID: trackID)
        let tracksByID = [
            trackID: TrackRecord(
                catalogID: "catalog-1",
                libraryID: "library-1",
                title: "Track",
                artistName: "Sample Artist"
            )
        ]

        let matchedByCatalog = PlaybackQueueBuilder.playlistItem(
            matching: "catalog-1",
            items: [item],
            tracksByID: tracksByID
        )
        let matchedByLibrary = PlaybackQueueBuilder.playlistItem(
            matching: "library-1",
            items: [item],
            tracksByID: tracksByID
        )

        #expect(matchedByCatalog?.id == item.id)
        #expect(matchedByLibrary?.id == item.id)
    }
}
