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
        #expect(controller.displayedSkipCount == 1)
        #expect(!controller.isPlaying)
        #expect(!controller.canControlPlayback)
        #expect(controller.playbackItemMetadataVersion > 0)
    }

    @Test("keep current refreshes displayed skip count")
    func keepCurrentRefreshesDisplayedSkipCount() throws {
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
        let settings = OverplaySettings(protectKeptTracks: false)
        context.insert(settings)
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
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 2
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
        #expect(controller.displayedSkipCount == 2)

        controller.keepCurrent(settings: settings, context: context)

        #expect(item.skipCount == 0)
        #expect(controller.displayedSkipCount == 0)
    }

    @Test("evaluate active session resolves playlist item from session track id")
    func evaluateActiveSessionResolvesPlaylistItemFromSessionTrackID() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let controller = PlaybackController()
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )
        context.insert(settings)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "catalog-1",
            libraryID: "library-1",
            title: "Target Track",
            artistName: "Artist",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 0
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(item)

        controller.currentPlaylistID = playlist.musicPlaylistID
        controller.currentTrack = CurrentPlaybackTrack(track, musicItemID: "library-1", item: nil)
        controller.currentPlaylistItem = nil
        controller.elapsedSeconds = 15
        controller.durationSeconds = 180

        await controller.evaluateActiveSessionForTesting(
            settings: settings,
            context: context,
            naturalCompletion: false
        )

        #expect(item.skipCount == 1)
        #expect(controller.displayedSkipCount == 1)
    }

    @Test("previous navigation does not count a skip on the outgoing track")
    func previousNavigationDoesNotCountSkip() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let controller = PlaybackController()
        let settings = OverplaySettings(
            skipThresholdPercentage: 50,
            minimumSkipListeningSeconds: 0
        )
        context.insert(settings)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Target Track",
            artistName: "Artist",
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 0
        )
        context.insert(playlist)
        context.insert(track)
        context.insert(item)

        controller.currentPlaylistID = playlist.musicPlaylistID
        controller.currentTrack = CurrentPlaybackTrack(track, musicItemID: "music-1", item: item)
        controller.currentPlaylistItem = item
        controller.elapsedSeconds = 15
        controller.durationSeconds = 180

        controller.markActiveSessionEvaluatedWithoutSkipForTesting()
        await controller.evaluateActiveSessionForTesting(
            settings: settings,
            context: context,
            naturalCompletion: false
        )

        #expect(item.skipCount == 0)
        #expect(controller.displayedSkipCount == 0)
    }
}
