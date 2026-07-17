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
        )

        #expect(detail.rows.map(\.id) == [secondItem.id, firstItem.id])
        #expect(detail.rows.map(\.summary.title) == ["Second", "First"])
        #expect(detail.rows[1].summary.subtitle == "Artist - Album")
        #expect(detail.rows[1].summary.artworkURLString == "https://example.com/first.jpg")
        #expect(detail.rows[0].isCurrent)
        #expect(detail.summary.knownCount == 3)
        #expect(detail.summary.playableCount == 2)
        #expect(detail.summary.evictedCount == 1)
        #expect(detail.playlist.playableTrackCount == 2)
        #expect(detail.playlist.isCurrentPlaybackPlaylist)

        let retiredDetail = viewModel.detailPresentation(
            for: playlist,
            playlistItems: [firstItem, otherItem, secondItem, evictedItem],
            tracks: [otherTrack, evictedTrack, firstTrack, secondTrack],
            playbackOrderState: state,
            currentPlaylistID: playlist.musicPlaylistID,
            currentPlaylistItem: secondItem,
            currentTrack: CurrentPlaybackTrack(id: "second", title: "Second", artistName: "Artist"),
            scope: .retired,
        )

        #expect(retiredDetail.rows.map(\.id) == [evictedItem.id])
        #expect(retiredDetail.rows.first?.summary.title == "Evicted")
        #expect(retiredDetail.rows.first?.summary.isPlayable == true)
        #expect(retiredDetail.rows.first?.summary.isRetired == true)
    }

    @Test("row summary changes when skip count changes")
    func rowSummaryChangesWhenSkipCountChanges() {
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
        )

        #expect(before.rows.first?.id == after.rows.first?.id)
        #expect(before.rows.first?.summary.skipCount == 1)
        #expect(after.rows.first?.summary.skipCount == 2)
    }

    @Test("row identity is stable when current highlight changes")
    func rowIdentityIsStableWhenCurrentHighlightChanges() {
        let viewModel = PlaylistManagementViewModel()
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        let track = TrackRecord(catalogID: "track", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)

        let before = viewModel.detailPresentation(
            for: playlist,
            playlistItems: [item],
            tracks: [track],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: playlist.musicPlaylistID),
            currentPlaylistID: playlist.musicPlaylistID,
            currentPlaylistItem: nil,
            currentTrack: nil,
        )

        let after = viewModel.detailPresentation(
            for: playlist,
            playlistItems: [item],
            tracks: [track],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: playlist.musicPlaylistID),
            currentPlaylistID: playlist.musicPlaylistID,
            currentPlaylistItem: item,
            currentTrack: CurrentPlaybackTrack(id: "track", title: "Track", artistName: "Artist"),
        )

        #expect(before.rows.first?.id == after.rows.first?.id)
        #expect(before.rows.first?.isCurrent == false)
        #expect(after.rows.first?.isCurrent == true)
    }

    @Test("current playlist detail uses active snapshot rows")
    func currentPlaylistDetailUsesActiveSnapshotRows() {
        let viewModel = PlaylistManagementViewModel()
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        let staleTrack = TrackRecord(catalogID: "stale", title: "Stale", artistName: "Artist")
        let freshTrack = TrackRecord(catalogID: "fresh", title: "Fresh", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: staleTrack.id, skipCount: 1)
        let snapshotItem = PlaylistItemRecord(playlistID: playlist.id, trackID: freshTrack.id, skipCount: 4)
        snapshotItem.id = item.id
        let snapshot = ActivePlaylistSnapshot(
            playlist: playlist,
            items: [snapshotItem],
            tracks: [freshTrack],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: playlist.musicPlaylistID),
            currentPlaylistItemID: item.id
        )

        let detail = viewModel.detailPresentation(
            for: playlist,
            playlistItems: [item],
            tracks: [staleTrack],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: playlist.musicPlaylistID),
            currentPlaylistID: playlist.musicPlaylistID,
            currentPlaylistItem: item,
            currentTrack: CurrentPlaybackTrack(id: "fresh", title: "Fresh", artistName: "Artist"),
            activePlaylistSnapshot: snapshot,
        )

        #expect(detail.rows.map(\.id) == [item.id])
        #expect(detail.rows.first?.item == nil)
        #expect(detail.rows.first?.summary.title == "Fresh")
        #expect(detail.rows.first?.summary.skipCount == 4)
        #expect(detail.rows.first?.isCurrent == true)
        #expect(detail.summary.skippedCount == 1)
        #expect(detail.playlist.isCurrentPlaybackPlaylist)
    }

    @Test("scope mismatch ignores active snapshot and uses selected persisted order")
    func scopeMismatchIgnoresActiveSnapshotAndUsesSelectedPersistedOrder() {
        let viewModel = PlaylistManagementViewModel()
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        let retiredFirstTrack = TrackRecord(catalogID: "retired-first", title: "Retired First", artistName: "Artist")
        let retiredSecondTrack = TrackRecord(catalogID: "retired-second", title: "Retired Second", artistName: "Artist")
        let retiredFirstItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: retiredFirstTrack.id,
            evictedAt: Date(timeIntervalSince1970: 100),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let retiredSecondItem = PlaylistItemRecord(
            playlistID: playlist.id,
            trackID: retiredSecondTrack.id,
            evictedAt: Date(timeIntervalSince1970: 200),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let activeSnapshot = ActivePlaylistSnapshot(
            playlist: playlist,
            items: [retiredFirstItem, retiredSecondItem],
            tracks: [retiredFirstTrack, retiredSecondTrack],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: playlist.musicPlaylistID),
            playbackScope: .active
        )
        let retiredOrder = PlaybackOrderState(
            playerID: "player",
            musicPlaylistID: PlaylistPlaybackScope.retired.playbackOrderPlaylistID(for: playlist.musicPlaylistID),
            orderedTrackIDs: [
                retiredSecondTrack.id.uuidString,
                retiredFirstTrack.id.uuidString
            ]
        )

        let detail = viewModel.detailPresentation(
            for: playlist,
            playlistItems: [retiredFirstItem, retiredSecondItem],
            tracks: [retiredFirstTrack, retiredSecondTrack],
            playbackOrderState: retiredOrder,
            currentPlaylistID: playlist.musicPlaylistID,
            currentPlaylistItem: nil,
            currentTrack: CurrentPlaybackTrack(id: "retired-second", title: "Retired Second", artistName: "Artist"),
            activePlaylistSnapshot: activeSnapshot,
            scope: .retired,
        )

        #expect(detail.rows.map(\.id) == [retiredSecondItem.id, retiredFirstItem.id])
        #expect(detail.rows.map(\.summary.title) == ["Retired Second", "Retired First"])
    }

    @Test("non-current playlist detail ignores active snapshot")
    func nonCurrentPlaylistDetailIgnoresActiveSnapshot() {
        let viewModel = PlaylistManagementViewModel()
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main", role: .oneTruePlaylist)
        let activePlaylist = PlaylistRecord(musicPlaylistID: "active", name: "Active")
        let track = TrackRecord(catalogID: "track", title: "SwiftData", artistName: "Artist")
        let activeTrack = TrackRecord(catalogID: "active", title: "Active", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, skipCount: 1)
        let activeItem = PlaylistItemRecord(playlistID: activePlaylist.id, trackID: activeTrack.id, skipCount: 5)
        let snapshot = ActivePlaylistSnapshot(
            playlist: activePlaylist,
            items: [activeItem],
            tracks: [activeTrack],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: activePlaylist.musicPlaylistID),
            currentPlaylistItemID: activeItem.id
        )

        let detail = viewModel.detailPresentation(
            for: playlist,
            playlistItems: [item],
            tracks: [track],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: playlist.musicPlaylistID),
            currentPlaylistID: activePlaylist.musicPlaylistID,
            currentPlaylistItem: activeItem,
            currentTrack: CurrentPlaybackTrack(id: "active", title: "Active", artistName: "Artist"),
            activePlaylistSnapshot: snapshot,
        )

        #expect(detail.rows.first?.item?.id == item.id)
        #expect(detail.rows.first?.summary.title == "SwiftData")
        #expect(detail.rows.first?.summary.skipCount == 1)
        #expect(detail.playlist.isCurrentPlaybackPlaylist == false)
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

    @Test("current item can use display local track ID while MusicKit ID is unresolved")
    func currentItemCanUseDisplayLocalTrackID() {
        let viewModel = PlaylistManagementViewModel()
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let track = TrackRecord(catalogID: "catalog", libraryID: "library", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id)

        let detail = viewModel.detailPresentation(
            for: playlist,
            playlistItems: [item],
            tracks: [track],
            playbackOrderState: PlaybackOrderState(playerID: "player", musicPlaylistID: playlist.musicPlaylistID),
            currentPlaylistID: playlist.musicPlaylistID,
            currentPlaylistItem: nil,
            currentLocalTrackID: track.id.uuidString,
            currentTrack: CurrentPlaybackTrack(id: "runtime-only", title: "Track", artistName: "Artist"),
        )

        #expect(detail.rows.first?.isCurrent == true)
        #expect(detail.playlist.isCurrentPlaybackPlaylist)
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
            playPlaylistFromTrack: { _, _, _, _, _ in
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

    @Test("play allows retired items in retired scope")
    func playAllowsRetiredItemsInRetiredScope() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(musicPlaylistID: "main", name: "Main")
        let settings = OverplaySettings()
        let track = TrackRecord(catalogID: "track", title: "Track", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: playlist.id, trackID: track.id, evictedAt: .now)
        let viewModel = PlaylistManagementViewModel()
        var playedScope: PlaylistPlaybackScope?
        let dependencies = makeDependencies(
            playPlaylistFromTrack: { _, _, scope, _, _ in
                playedScope = scope
            }
        )

        await viewModel.play(
            item,
            track: track,
            playlist: playlist,
            settings: settings,
            scope: .retired,
            context: context,
            dependencies: dependencies
        )

        #expect(playedScope == .retired)
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
            promote: { item, _, _ in
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
            promote: { _, _, _ in
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
        #expect(viewModel.message == "Retired Track.")
    }

    private func makeDependencies(
        playPlaylistFromTrack: @escaping (PlaylistRecord, TrackRecord, PlaylistPlaybackScope, OverplaySettings, ModelContext) async -> Void = { _, _, _, _, _ in },
        playPlaylist: @escaping (PlaylistRecord, PlaylistPlaybackScope, OverplaySettings, ModelContext) async -> Void = { _, _, _, _ in },
        syncPlaylist: @escaping (PlaylistRecord, ModelContext) async throws -> Int = { _, _ in 0 },
        reconcileStoredOrder: @escaping (PlaylistRecord, ModelContext) -> Void = { _, _ in },
        promote: @escaping (PlaylistItemRecord, PlaylistRecord, ModelContext) async throws -> Void = { _, _, _ in },
        evict: @escaping (PlaylistItemRecord, PlaylistRecord, ModelContext) throws -> Void = { _, _, _ in },
        restore: @escaping (PlaylistItemRecord, PlaylistRecord, ModelContext) throws -> Void = { _, _, _ in }
    ) -> PlaylistManagementViewModel.Dependencies {
        PlaylistManagementViewModel.Dependencies(
            playPlaylistFromTrack: playPlaylistFromTrack,
            playPlaylist: playPlaylist,
            syncPlaylist: syncPlaylist,
            reconcileStoredOrder: reconcileStoredOrder,
            promote: promote,
            evict: evict,
            restore: restore
        )
    }
}
