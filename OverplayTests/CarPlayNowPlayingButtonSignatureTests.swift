import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("CarPlay now playing button signature")
struct CarPlayNowPlayingButtonSignatureTests {
    @Test("reflects current track health and playback mode state")
    func reflectsCurrentTrackHealthAndPlaybackModeState() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let controller = PlaybackController()
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Ready Track",
            artistName: "Ready Artist"
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 2,
            protected: true
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(item)

        controller.currentPlaylistID = playlist.musicPlaylistID
        controller.currentTrack = CurrentPlaybackTrack(
            id: "music-1",
            title: track.title,
            artistName: track.artistName
        )
        controller.currentPlaylistItem = item
        controller.setRepeatEnabled(true)

        let signature = CarPlayNowPlayingButtonSignature.make(from: controller)

        #expect(signature.trackID == "music-1")
        #expect(signature.skipCount == 2)
        #expect(signature.isProtected)
        #expect(!signature.isEvicted)
        #expect(!signature.shuffleEnabled)
        #expect(signature.repeatEnabled)
    }
}
