import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playlist management view model")
struct PlaylistManagementViewModelTests {
    @Test("ordered items filters by playlist and follows playback mode state")
    func orderedItemsFilterAndFollowPlaybackState() {
        let viewModel = PlaylistManagementViewModel()
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let otherPlaylist = PlaylistRecord(musicPlaylistID: "other", name: "Other")
        let firstTrack = TrackRecord(catalogID: "first", title: "First", artistName: "Artist")
        let secondTrack = TrackRecord(catalogID: "second", title: "Second", artistName: "Artist")
        let otherTrack = TrackRecord(catalogID: "other", title: "Other", artistName: "Artist")
        let firstItem = PlaylistItemRecord(playlistID: playlist.id, trackID: firstTrack.id, sortOrder: 0)
        let secondItem = PlaylistItemRecord(playlistID: playlist.id, trackID: secondTrack.id, sortOrder: 1)
        let otherItem = PlaylistItemRecord(playlistID: otherPlaylist.id, trackID: otherTrack.id, sortOrder: 0)
        let state = PlaybackModeState(
            playerID: "player",
            musicPlaylistID: playlist.musicPlaylistID,
            shuffleEnabled: true,
            orderedTrackIDs: [secondTrack.id.uuidString, firstTrack.id.uuidString]
        )

        let orderedItems = viewModel.orderedItems(
            for: playlist,
            playlistItems: [firstItem, otherItem, secondItem],
            playbackModeState: state
        )

        #expect(orderedItems.map(\.id) == [secondItem.id, firstItem.id])
    }

    @Test("current track matches catalog or library identifier")
    func currentTrackMatchesKnownMusicIdentifiers() {
        let viewModel = PlaylistManagementViewModel()
        let track = TrackRecord(catalogID: "catalog", libraryID: "library", title: "Track", artistName: "Artist")

        #expect(viewModel.isCurrentTrack(track, currentTrack: CurrentPlaybackTrack(id: "catalog", title: "Track", artistName: "Artist")))
        #expect(viewModel.isCurrentTrack(track, currentTrack: CurrentPlaybackTrack(id: "library", title: "Track", artistName: "Artist")))
        #expect(!viewModel.isCurrentTrack(track, currentTrack: CurrentPlaybackTrack(id: "other", title: "Track", artistName: "Artist")))
    }

    @Test("sync reports success and reconciles stored order")
    func syncReportsSuccessAndReconcilesStoredOrder() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let viewModel = PlaylistManagementViewModel()
        var syncedPlaylistID: String?
        var reconciledPlaylistID: String?
        let dependencies = makeDependencies(
            syncPlaylist: { playlist, _ in
                syncedPlaylistID = playlist.musicPlaylistID
                return 7
            },
            reconcileStoredOrder: { playlist, _ in
                reconciledPlaylistID = playlist.musicPlaylistID
            }
        )

        await viewModel.syncPlaylist(playlist, context: context, dependencies: dependencies)

        #expect(syncedPlaylistID == "main")
        #expect(reconciledPlaylistID == "main")
        #expect(!viewModel.isSyncing)
        #expect(viewModel.message == "Synced 7 tracks from Main.")
    }

    @Test("play ignores unplayable items")
    func playIgnoresUnplayableItems() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let settings = OverplaySettings()
        let track = TrackRecord(catalogID: "track", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, evictedAt: .now)
        let viewModel = PlaylistManagementViewModel()
        var playCallCount = 0
        let dependencies = makeDependencies(
            playPlaylistFromTrack: { _, _, _, _ in
                playCallCount += 1
            }
        )

        await viewModel.play(
            item,
            track: track,
            playlist: playlist,
            settings: settings,
            context: context,
            dependencies: dependencies
        )

        #expect(playCallCount == 0)
    }

    @Test("promote triage item reports success and clears progress state")
    func promoteTriageItemReportsSuccessAndClearsProgressState() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "triage", name: "Triage", role: .triage)
        let track = TrackRecord(catalogID: "track", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)
        let viewModel = PlaylistManagementViewModel()
        var promotedItemID: UUID?
        let dependencies = makeDependencies(
            promote: { item, _ in
                promotedItemID = item.id
            }
        )

        await viewModel.promote(
            item,
            track: track,
            playlist: playlist,
            context: context,
            dependencies: dependencies
        )

        #expect(promotedItemID == item.id)
        #expect(viewModel.promotingItemIDs.isEmpty)
        #expect(viewModel.message == "Promoted Track.")
    }

    @Test("promote ignores non-triage playlists")
    func promoteIgnoresNonTriagePlaylists() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        let track = TrackRecord(catalogID: "track", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)
        let viewModel = PlaylistManagementViewModel()
        var promoteCallCount = 0
        let dependencies = makeDependencies(
            promote: { _, _ in
                promoteCallCount += 1
            }
        )

        await viewModel.promote(
            item,
            track: track,
            playlist: playlist,
            context: context,
            dependencies: dependencies
        )

        #expect(promoteCallCount == 0)
        #expect(viewModel.promotingItemIDs.isEmpty)
        #expect(viewModel.message == nil)
    }

    private func makeDependencies(
        playPlaylistFromTrack: @escaping (PlaylistRecord, TrackRecord, OverplaySettings, ModelContext) async -> Void = { _, _, _, _ in },
        playPlaylist: @escaping (PlaylistRecord, OverplaySettings, ModelContext) async -> Void = { _, _, _ in },
        syncPlaylist: @escaping (PlaylistRecord, ModelContext) async throws -> Int = { _, _ in 0 },
        reconcileStoredOrder: @escaping (PlaylistRecord, ModelContext) -> Void = { _, _ in },
        promote: @escaping (PlaylistItemRecord, ModelContext) async throws -> Void = { _, _ in }
    ) -> PlaylistManagementViewModel.Dependencies {
        PlaylistManagementViewModel.Dependencies(
            playPlaylistFromTrack: playPlaylistFromTrack,
            playPlaylist: playPlaylist,
            syncPlaylist: syncPlaylist,
            reconcileStoredOrder: reconcileStoredOrder,
            promote: promote
        )
    }
}
