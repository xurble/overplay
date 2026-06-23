import Foundation
import Testing
@testable import Overplay

@Suite("Playlist display order")
struct PlaylistDisplayOrderTests {
    @Test("uses stored local order before created fallback order")
    func usesStoredLocalOrderBeforeCreatedFallbackOrder() {
        let playlistID = UUID()
        let items = [
            PlaylistItemRecord(playlistID: playlistID, trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, sortOrder: 0),
            PlaylistItemRecord(playlistID: playlistID, trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, sortOrder: 1),
            PlaylistItemRecord(playlistID: playlistID, trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, sortOrder: 2),
            PlaylistItemRecord(playlistID: playlistID, trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, sortOrder: 3)
        ]
        let state = PlaybackOrderState(
            playerID: "main",
            musicPlaylistID: "playlist-1",
            orderedTrackIDs: [
                "00000000-0000-0000-0000-000000000003",
                "00000000-0000-0000-0000-000000000001"
            ]
        )

        let orderedIDs = PlaylistDisplayOrder.orderedItems(items, state: state).map(\.trackID.uuidString)

        #expect(orderedIDs == [
            "00000000-0000-0000-0000-000000000003",
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000004"
        ])
    }
}
