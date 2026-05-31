import Foundation
import Testing
@testable import Overplay

@Suite("Current playback track")
struct CurrentPlaybackTrackTests {
    @Test("snapshot copies playlist item and track record state")
    func snapshotCopiesPlaylistItemAndTrackRecordState() {
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Original",
            artistName: "Sample Artist",
            albumTitle: "Sample Album",
            artworkURLTemplate: "https://example.com/artwork.jpg",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: UUID(),
            trackID: track.id,
            skipCount: 2,
            playthroughCount: 3,
            evictedAt: Date(timeIntervalSince1970: 100),
            protected: true
        )

        let currentTrack = CurrentPlaybackTrack(track, musicItemID: "catalog-1", item: item)
        track.title = "Changed"
        item.skipCount = 9

        #expect(currentTrack.id == "catalog-1")
        #expect(currentTrack.title == "Original")
        #expect(currentTrack.skipCount == 2)
        #expect(currentTrack.playthroughCount == 3)
        #expect(currentTrack.isEvicted)
        #expect(currentTrack.protected)
    }
}
