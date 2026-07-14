import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("CarPlay now playing button signature", .serialized)
struct CarPlayNowPlayingButtonSignatureTests {
    @Test("reflects presentation state for track health")
    func reflectsPresentationState() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = try SettingsRepository.settings(in: context)
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

        let signature = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            settings: settings,
            context: context
        )
        let nowPlaying = NowPlayingPresentationFactory.presentation(
            playbackController: controller,
            settings: settings,
            context: context
        )
        let health = NowPlayingPresentationFactory.trackHealthPresentation(
            playbackController: controller,
            settings: settings,
            context: context
        )

        #expect(signature.trackID == nowPlaying.trackID)
        #expect(signature.playlistRole == .oneTruePlaylist)
        #expect(signature.skipCount == nowPlaying.skipCount)
        #expect(signature.isProtected == nowPlaying.isProtected)
        #expect(signature.isEvicted == nowPlaying.isEvicted)
        #expect(health.title == "Protected")
    }

    @Test("changes when evicted and at-risk presentation state changes")
    func changesWithHealthPresentation() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = try SettingsRepository.settings(in: context)
        settings.evictAfterSkips = 3
        let controller = PlaybackController()
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Track",
            artistName: "Artist"
        )
        context.insert(playlist)
        context.insert(track)
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, skipCount: 2)
        context.insert(item)
        controller.currentPlaylistID = playlist.musicPlaylistID
        controller.currentTrack = CurrentPlaybackTrack(id: "music-1", title: "Track", artistName: "Artist")
        controller.currentPlaylistItem = item

        let atRisk = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            settings: settings,
            context: context
        )
        let atRiskHealth = NowPlayingPresentationFactory.trackHealthPresentation(
            playbackController: controller,
            settings: settings,
            context: context
        )
        #expect(atRiskHealth.status == .critical)
        #expect(!atRisk.isEvicted)

        item.evictedAt = Date.now
        controller.currentPlaylistItem = item

        let evicted = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            settings: settings,
            context: context
        )
        let evictedHealth = NowPlayingPresentationFactory.trackHealthPresentation(
            playbackController: controller,
            settings: settings,
            context: context
        )
        #expect(evicted.isEvicted)
        #expect(evictedHealth.title == "Evicted")
        #expect(evicted != atRisk)
    }

    @Test("factory reflects triage playlist role for direct CarPlay actions")
    func factoryReflectsTriagePlaylistRoleForDirectCarPlayActions() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = try SettingsRepository.settings(in: context)
        let controller = PlaybackController()
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-2",
            name: "Triage",
            role: .triage
        )
        let track = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "Track",
            artistName: "Artist",
            durationSeconds: 100
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)
        context.insert(playlist)
        context.insert(track)
        context.insert(item)

        controller.currentPlaylistID = playlist.musicPlaylistID
        controller.currentTrack = CurrentPlaybackTrack(
            id: "music-1",
            title: "Track",
            artistName: "Artist",
            durationSeconds: 100
        )
        controller.currentPlaylistItem = item
        controller.durationSeconds = 100

        let signature = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            settings: settings,
            context: context
        )

        #expect(signature.playlistRole == .triage)
    }
}
