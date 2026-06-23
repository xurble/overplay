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
        #expect(signature.skipCount == nowPlaying.skipCount)
        #expect(signature.isProtected == nowPlaying.isProtected)
        #expect(signature.isEvicted == nowPlaying.isEvicted)
        #expect(signature.skipForwardIntent == .standard)
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

    @Test("maps skip intent to CarPlay action menu icon")
    func mapsSkipIntentToCarPlayActionMenuIcon() {
        var signature = CarPlayNowPlayingButtonSignature(
            trackID: nil,
            skipCount: 0,
            isProtected: false,
            isEvicted: false,
            skipForwardIntent: .standard
        )

        #expect(signature.trackActionMenuSystemImage == "info.circle.fill")

        signature.skipForwardIntent = .skipCountReset
        #expect(signature.trackActionMenuSystemImage == "info.circle.fill")

        signature.skipForwardIntent = .countedSkip
        #expect(signature.trackActionMenuSystemImage == "exclamationmark.triangle.fill")

        signature.skipForwardIntent = .eviction
        #expect(signature.trackActionMenuSystemImage == "exclamationmark.octagon.fill")
    }

    @Test("factory maps current skip prediction to CarPlay action menu icon")
    func factoryMapsCurrentSkipPredictionToCarPlayActionMenuIcon() throws {
        let fixture = try makePredictionFixture(skipCount: 0)

        fixture.controller.elapsedSeconds = 4
        #expect(carPlayActionIcon(fixture) == "info.circle.fill")

        fixture.controller.elapsedSeconds = 15
        #expect(carPlayActionIcon(fixture) == "exclamationmark.triangle.fill")

        fixture.item.skipCount = 2
        #expect(carPlayActionIcon(fixture) == "exclamationmark.octagon.fill")

        fixture.controller.elapsedSeconds = 92
        fixture.settings.playthroughResetsSkipCount = true
        fixture.settings.playthroughThresholdPercentage = 90
        #expect(carPlayActionIcon(fixture) == "info.circle.fill")
    }

    private func carPlayActionIcon(_ fixture: PredictionFixture) -> String {
        CarPlayNowPlayingButtonSignature.make(
            playbackController: fixture.controller,
            settings: fixture.settings,
            context: fixture.context
        ).trackActionMenuSystemImage
    }

    private func makePredictionFixture(skipCount: Int) throws -> PredictionFixture {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let settings = try SettingsRepository.settings(in: context)
        settings.evictAfterSkips = 3
        settings.skipThresholdPercentage = 50
        settings.minimumSkipListeningSeconds = 10
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
            artistName: "Artist",
            durationSeconds: 100
        )
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, skipCount: skipCount)
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

        return PredictionFixture(
            container: container,
            context: context,
            settings: settings,
            controller: controller,
            item: item
        )
    }

    private struct PredictionFixture {
        var container: ModelContainer
        var context: ModelContext
        var settings: OverplaySettings
        var controller: PlaybackController
        var item: PlaylistItemRecord
    }
}
