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
        let state = PlaybackOrderState(
            playerID: "player",
            musicPlaylistID: playlist.musicPlaylistID,
            orderedTrackIDs: [secondTrack.id.uuidString, firstTrack.id.uuidString]
        )

        let orderedItems = viewModel.orderedItems(
            for: playlist,
            playlistItems: [firstItem, otherItem, secondItem],
            playbackOrderState: state
        )

        #expect(orderedItems.map(\.id) == [secondItem.id, firstItem.id])
    }

    @Test("detail presentation builds ordered rows with summaries and counts")
    func detailPresentationBuildsRowsWithSummariesAndCounts() {
        let viewModel = PlaylistManagementViewModel()
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        let otherPlaylist = PlaylistRecord(musicPlaylistID: "other", name: "Other")
        let firstTrack = TrackRecord(
            catalogID: "first",
            title: "First",
            artistName: "Artist",
            albumTitle: "Album",
            artworkURLTemplate: "https://example.com/first.jpg"
        )
        let secondTrack = TrackRecord(catalogID: "second", title: "Second", artistName: "Artist")
        let evictedTrack = TrackRecord(catalogID: "evicted", title: "Evicted", artistName: "Artist")
        let otherTrack = TrackRecord(catalogID: "other", title: "Other", artistName: "Artist")
        let firstItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: firstTrack.id,
            sortOrder: 0,
            skipCount: 1
        )
        let secondItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: secondTrack.id,
            sortOrder: 1
        )
        let evictedItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: evictedTrack.id,
            sortOrder: 2,
            skipCount: 3,
            evictedAt: .now
        )
        let otherItem = PlaylistItemRecord(playlistID: otherPlaylist.id, trackID: otherTrack.id, sortOrder: 0)
        let state = PlaybackOrderState(
            playerID: "player",
            musicPlaylistID: playlist.musicPlaylistID,
            orderedTrackIDs: [
                secondTrack.id.uuidString,
                firstTrack.id.uuidString,
                evictedTrack.id.uuidString
            ]
        )

        let detail = viewModel.detailPresentation(
            for: playlist,
            playlistItems: [firstItem, otherItem, secondItem, evictedItem],
            tracks: [otherTrack, evictedTrack, firstTrack, secondTrack],
            playbackOrderState: state,
            currentPlaylistID: playlist.musicPlaylistID,
            currentPlaylistItem: secondItem,
            currentTrack: CurrentPlaybackTrack(id: "second", title: "Second", artistName: "Artist"),
            evictAfterSkips: 3
        )

        #expect(detail.rows.map(\.id) == [secondItem.id, firstItem.id, evictedItem.id])
        #expect(detail.rows.map(\.summary.title) == ["Second", "First", "Evicted"])
        #expect(detail.rows[1].summary.subtitle == "Artist - Album")
        #expect(detail.rows[1].summary.artworkURLString == "https://example.com/first.jpg")
        #expect(detail.rows[2].summary.isPlayable == false)
        #expect(detail.rows[0].isCurrent)
        #expect(detail.summary.knownCount == 3)
        #expect(detail.summary.playableCount == 2)
        #expect(detail.summary.evictedCount == 1)
        #expect(detail.playlist.playableTrackCount == 2)
        #expect(detail.playlist.isCurrentPlaybackPlaylist)
    }

    @Test("row render identity changes when skip count changes")
    func rowRenderIdentityChangesWhenSkipCountChanges() {
        let viewModel = PlaylistManagementViewModel()
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        let track = TrackRecord(catalogID: "track", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, skipCount: 1)

        let before = viewModel.detailPresentation(
            for: playlist,
            playlistItems: [item],
            tracks: [track],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: playlist.musicPlaylistID),
            currentPlaylistID: playlist.musicPlaylistID,
            currentPlaylistItem: item,
            currentTrack: CurrentPlaybackTrack(id: "track", title: "Track", artistName: "Artist"),
            playbackItemMetadataVersion: 0,
            evictAfterSkips: 3
        )

        item.skipCount = 2

        let after = viewModel.detailPresentation(
            for: playlist,
            playlistItems: [item],
            tracks: [track],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: playlist.musicPlaylistID),
            currentPlaylistID: playlist.musicPlaylistID,
            currentPlaylistItem: item,
            currentTrack: CurrentPlaybackTrack(id: "track", title: "Track", artistName: "Artist"),
            playbackItemMetadataVersion: 1,
            evictAfterSkips: 3
        )

        #expect(before.rows.first?.id == after.rows.first?.id)
        #expect(before.rows.first?.summary.skipCount == 1)
        #expect(after.rows.first?.summary.skipCount == 2)
        #expect(before.rows.first?.renderID != after.rows.first?.renderID)
    }

    @Test("current item uses shared current playlist item matcher")
    func currentItemUsesSharedCurrentPlaylistItemMatcher() {
        let viewModel = PlaylistManagementViewModel()
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let track = TrackRecord(catalogID: "catalog", libraryID: "library", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)

        #expect(viewModel.isCurrentItem(
            item,
            track: track,
            playlist: playlist,
            currentPlaylistID: "main",
            currentPlaylistItem: item,
            currentTrack: CurrentPlaybackTrack(id: "other", title: "Track", artistName: "Artist")
        ))
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

    @Test("evict playable item reports success and clears progress state")
    func evictPlayableItemReportsSuccessAndClearsProgressState() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "triage", name: "Triage", role: .triage)
        let track = TrackRecord(catalogID: "track", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)
        let viewModel = PlaylistManagementViewModel()
        var evictedItemID: UUID?
        var evictedPlaylistID: UUID?
        let dependencies = makeDependencies(
            evict: { item, playlist, _ in
                evictedItemID = item.id
                evictedPlaylistID = playlist.id
            }
        )

        await viewModel.evict(
            item,
            track: track,
            playlist: playlist,
            context: context,
            dependencies: dependencies
        )

        #expect(evictedItemID == item.id)
        #expect(evictedPlaylistID == playlist.id)
        #expect(viewModel.evictingItemIDs.isEmpty)
        #expect(viewModel.message == "Evicted Track.")
    }

    private func makeDependencies(
        playPlaylistFromTrack: @escaping (PlaylistRecord, TrackRecord, OverplaySettings, ModelContext) async -> Void = { _, _, _, _ in },
        playPlaylist: @escaping (PlaylistRecord, OverplaySettings, ModelContext) async -> Void = { _, _, _ in },
        syncPlaylist: @escaping (PlaylistRecord, ModelContext) async throws -> Int = { _, _ in 0 },
        reconcileStoredOrder: @escaping (PlaylistRecord, ModelContext) -> Void = { _, _ in },
        promote: @escaping (PlaylistItemRecord, ModelContext) async throws -> Void = { _, _ in },
        evict: @escaping (PlaylistItemRecord, PlaylistRecord, ModelContext) throws -> Void = { _, _, _ in }
    ) -> PlaylistManagementViewModel.Dependencies {
        PlaylistManagementViewModel.Dependencies(
            playPlaylistFromTrack: playPlaylistFromTrack,
            playPlaylist: playPlaylist,
            syncPlaylist: syncPlaylist,
            reconcileStoredOrder: reconcileStoredOrder,
            promote: promote,
            evict: evict
        )
    }
}
