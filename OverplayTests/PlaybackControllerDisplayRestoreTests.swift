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

    @Test("reset current skip count refreshes displayed metadata")
    func resetCurrentSkipCountRefreshesDisplayedMetadata() throws {
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
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 3
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
        let previousMetadataVersion = controller.playbackItemMetadataVersion
        #expect(controller.displayedSkipCount == 3)

        controller.resetCurrentSkipCount(context: context, message: "Skip count reset in CarPlay")

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.skipCount == 0)
        #expect(controller.displayedSkipCount == 0)
        #expect(controller.playbackItemMetadataVersion > previousMetadataVersion)
        #expect(history.first?.message == "Skip count reset in CarPlay")
    }

    @Test("protect current track refreshes displayed metadata")
    func protectCurrentTrackRefreshesDisplayedMetadata() throws {
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
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 3,
            protected: false
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
        let previousMetadataVersion = controller.playbackItemMetadataVersion
        #expect(!controller.displayedIsProtected)

        controller.protectCurrentTrack(context: context, message: "Protected in CarPlay")

        let history = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(item.protected)
        #expect(controller.displayedIsProtected)
        #expect(controller.playbackItemMetadataVersion > previousMetadataVersion)
        #expect(history.first?.message == "Protected in CarPlay")

        let protectedMetadataVersion = controller.playbackItemMetadataVersion
        controller.toggleCurrentKeep(
            context: context,
            enabledMessage: "Keep turned on in CarPlay",
            disabledMessage: "Keep turned off in CarPlay"
        )

        let updatedHistory = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(!item.protected)
        #expect(!controller.displayedIsProtected)
        #expect(controller.playbackItemMetadataVersion > protectedMetadataVersion)
        #expect(updatedHistory.compactMap(\.message).contains("Keep turned off in CarPlay"))
    }

    @Test("reset all local stats refreshes displayed metadata")
    func resetAllLocalStatsRefreshesDisplayedMetadata() throws {
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
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            skipCount: 4,
            playthroughCount: 2,
            evictedAt: Date(timeIntervalSince1970: 200),
            protected: true
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
        let previousMetadataVersion = controller.playbackItemMetadataVersion
        #expect(controller.displayedSkipCount == 4)
        #expect(controller.displayedPlaythroughCount == 2)
        #expect(controller.displayedIsProtected)
        #expect(controller.displayedIsEvicted)

        try controller.resetAllLocalStats(context: context)

        #expect(item.skipCount == 0)
        #expect(item.playthroughCount == 0)
        #expect(item.evictedAt == nil)
        #expect(!item.protected)
        #expect(controller.displayedSkipCount == 0)
        #expect(controller.displayedPlaythroughCount == 0)
        #expect(!controller.displayedIsProtected)
        #expect(!controller.displayedIsEvicted)
        #expect(controller.playbackItemMetadataVersion > previousMetadataVersion)
    }

    @Test("restore track refreshes displayed metadata")
    func restoreTrackRefreshesDisplayedMetadata() throws {
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
            durationSeconds: 180
        )
        let item = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: track.id,
            evictedAt: Date(timeIntervalSince1970: 200)
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
        let previousMetadataVersion = controller.playbackItemMetadataVersion
        #expect(controller.displayedIsEvicted)

        try controller.restoreTrack(item, playlist: playlist, context: context)

        #expect(item.evictedAt == nil)
        #expect(!controller.displayedIsEvicted)
        #expect(controller.playbackItemMetadataVersion > previousMetadataVersion)
    }
}
