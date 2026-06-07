import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playback controller display restore")
struct PlaybackControllerDisplayRestoreTests {
    @Test("restores mini player display from local database state")
    func restoresMiniPlayerDisplayFromLocalDatabaseState() throws {
        let previousState = LocalPlaybackStateStore.load()
        defer {
            if let previousState {
                LocalPlaybackStateStore.save(previousState)
            } else {
                LocalPlaybackStateStore.clear()
            }
        }

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
            artistName: "Ready Artist",
            albumTitle: "Ready Album",
            artworkURLTemplate: "https://example.com/artwork.jpg",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 1
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(item)
        LocalPlaybackStateStore.save(LocalPlaybackState(
            playlistID: playlist.musicPlaylistID,
            musicItemID: "music-1",
            elapsedSeconds: 42,
            wasPlaying: false,
            updatedAt: Date(timeIntervalSince1970: 100),
            localTrackID: track.id.uuidString
        ))

        controller.restoreLocalPlaybackDisplay(context: context)

        #expect(controller.currentPlaylistID == playlist.musicPlaylistID)
        #expect(controller.currentPlaylistItem?.id == item.id)
        #expect(controller.currentTrack?.title == "Ready Track")
        #expect(controller.currentTrack?.artistName == "Ready Artist")
        #expect(controller.currentTrack?.artworkURLTemplate == "https://example.com/artwork.jpg")
        #expect(controller.elapsedSeconds == 42)
        #expect(controller.durationSeconds == 180)
        #expect(!controller.isPlaying)
        #expect(!controller.canControlPlayback)
    }
}
