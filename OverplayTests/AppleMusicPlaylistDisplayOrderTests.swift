import Testing
@testable import Overplay

@Suite("Apple Music playlist display order")
struct AppleMusicPlaylistDisplayOrderTests {
    @Test("preferred Overplay playlists stay pinned before alphabetical results")
    func preferredOverplayPlaylistsStayPinnedBeforeAlphabeticalResults() {
        let playlists = [
            AppleMusicPlaylist(id: "z", name: "Z Road", trackCount: nil),
            AppleMusicPlaylist(id: "overplay", name: "overplay", trackCount: nil),
            AppleMusicPlaylist(id: "a", name: "A Quiet Library", trackCount: nil)
        ]

        let sorted = AppleMusicPlaylistDisplayOrder.sorted(playlists)

        #expect(sorted.map(\.id) == ["overplay", "a", "z"])
    }
}
