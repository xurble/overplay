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
        let playbackDefaults = PlaybackTestDefaults()
        defer { playbackDefaults.cleanUp() }
        let controller = PlaybackController(localPlaybackDefaults: playbackDefaults.defaults)
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
        let playbackDefaults = PlaybackTestDefaults()
        defer { playbackDefaults.cleanUp() }
        let controller = PlaybackController(localPlaybackDefaults: playbackDefaults.defaults)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-2",
            name: "Triage",
            role: .triageBucket
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
            context: context
        )

        #expect(signature.playlistRole == .triageBucket)
    }

    @Test("changes when the current playlist role changes")
    func changesWithCurrentPlaylistRole() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playbackDefaults = PlaybackTestDefaults()
        defer { playbackDefaults.cleanUp() }
        let controller = PlaybackController(localPlaybackDefaults: playbackDefaults.defaults)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-role-change",
            name: "Current",
            role: .triageBucket
        )
        context.insert(playlist)
        controller.currentPlaylistID = playlist.musicPlaylistID
        controller.currentTrack = CurrentPlaybackTrack(id: "music-1", title: "Track", artistName: "Artist")

        let triage = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            context: context
        )

        playlist.role = .oneTruePlaylist
        try context.save()

        let oneTruePlaylist = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            context: context
        )

        #expect(triage.playlistRole == .triageBucket)
        #expect(oneTruePlaylist.playlistRole == .oneTruePlaylist)
        #expect(oneTruePlaylist != triage)
    }

    @Test("does not change when only track identity and skip count change")
    func ignoresTrackIdentityAndSkipCount() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playbackDefaults = PlaybackTestDefaults()
        defer { playbackDefaults.cleanUp() }
        let controller = PlaybackController(localPlaybackDefaults: playbackDefaults.defaults)
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-stable-layout",
            name: "Main",
            role: .oneTruePlaylist
        )
        let firstTrack = TrackRecord(
            catalogID: "music-1",
            libraryID: "music-1",
            title: "First",
            artistName: "Artist"
        )
        let secondTrack = TrackRecord(
            catalogID: "music-2",
            libraryID: "music-2",
            title: "Second",
            artistName: "Artist"
        )
        let firstItem = PlaylistItemRecord(playlistID: playlist.id, trackID: firstTrack.id, skipCount: 1)
        let secondItem = PlaylistItemRecord(playlistID: playlist.id, trackID: secondTrack.id, skipCount: 8)
        context.insert(playlist)
        context.insert(firstTrack)
        context.insert(secondTrack)
        context.insert(firstItem)
        context.insert(secondItem)

        controller.currentPlaylistID = playlist.musicPlaylistID
        controller.currentTrack = CurrentPlaybackTrack(id: "music-1", title: "First", artistName: "Artist")
        controller.currentPlaylistItem = firstItem
        let first = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            context: context
        )

        controller.currentTrack = CurrentPlaybackTrack(id: "music-2", title: "Second", artistName: "Artist")
        controller.currentPlaylistItem = secondItem
        let second = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            context: context
        )

        #expect(second == first)
    }

    @Test("changes when track availability changes")
    func changesWithTrackAvailability() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playbackDefaults = PlaybackTestDefaults()
        defer { playbackDefaults.cleanUp() }
        let controller = PlaybackController(localPlaybackDefaults: playbackDefaults.defaults)

        let empty = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            context: context
        )

        controller.currentTrack = CurrentPlaybackTrack(id: "music-1", title: "Track", artistName: "Artist")
        let playing = CarPlayNowPlayingButtonSignature.make(
            playbackController: controller,
            context: context
        )

        #expect(!empty.hasCurrentTrack)
        #expect(playing.hasCurrentTrack)
        #expect(playing != empty)
    }
}
