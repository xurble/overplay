import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("CarPlay now playing button signature", .serialized)
struct CarPlayNowPlayingButtonSignatureTests {
    @Test("changes when retired presentation state changes")
    func changesWithRetiredPresentation() throws {
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

        let active = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            settings: settings,
            context: context
        )
        let activeBadge = NowPlayingPresentationFactory.trackStateBadgePresentation(
            playbackController: controller,
            settings: settings,
            context: context
        )
        #expect(activeBadge.title == "Active")
        #expect(!active.isEvicted)

        item.evictedAt = Date.now
        controller.currentPlaylistItem = item

        let evicted = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            settings: settings,
            context: context
        )
        let evictedBadge = NowPlayingPresentationFactory.trackStateBadgePresentation(
            playbackController: controller,
            settings: settings,
            context: context
        )
        #expect(evicted.isEvicted)
        #expect(evictedBadge.title == "Retired")
        #expect(evicted != active)
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
