import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playlist sync reconciliation")
struct PlaylistSyncReconciliationTests {
    @Test("reconcile inserts tracks and playlist items")
    func reconcileInsertsTracksAndPlaylistItems() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)

        let count = try PlaylistSyncService().reconcile(
            snapshots: [
                snapshot(id: "track-1", title: "First"),
                snapshot(id: "track-2", title: "Second")
            ],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )

        #expect(count == 2)
        #expect(try TrackRecordRepository.allTracks(in: context).count == 2)
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        #expect(items.count == 2)
        #expect(items.map(\.sortOrder) == [0, 1])
        #expect(playlist.lastSyncedAt == Date(timeIntervalSince1970: 100))
    }

    @Test("repeated reconcile does not duplicate tracks or playlist items")
    func repeatedReconcileDoesNotDuplicateTracksOrPlaylistItems() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)
        let snapshots = [
            snapshot(id: "track-1", title: "First"),
            snapshot(id: "track-2", title: "Second")
        ]

        try PlaylistSyncService().reconcile(
            snapshots: snapshots,
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        try PlaylistSyncService().reconcile(
            snapshots: snapshots,
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 200),
            in: context
        )

        #expect(try TrackRecordRepository.allTracks(in: context).count == 2)
        #expect(try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context).count == 2)
        #expect(playlist.lastSyncedAt == Date(timeIntervalSince1970: 200))
    }

    @Test("reconcile remote removals keeps local item playable")
    func reconcileRemoteRemovalsKeepsLocalItemPlayable() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)

        try PlaylistSyncService().reconcile(
            snapshots: [
                snapshot(id: "track-1", title: "First"),
                snapshot(id: "track-2", title: "Second")
            ],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        try PlaylistSyncService().reconcile(
            snapshots: [
                snapshot(id: "track-1", title: "First")
            ],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 200),
            in: context
        )

        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let tracksByID = try TrackRecordRepository.allTracks(in: context).firstValueDictionary(keyedBy: \.id)
        let missingRemoteItem = try #require(items.first { tracksByID[$0.trackID]?.catalogID == "track-2" })
        let activeItems = try PlaylistItemRepository.activeItems(forPlaylistID: playlist.id, in: context)
        let history = try context.fetch(FetchDescriptor<HistoryEvent>())

        #expect(missingRemoteItem.evictedAt == nil)
        #expect(missingRemoteItem.evictionReason == nil)
        #expect(missingRemoteItem.evictionSource == nil)
        #expect(missingRemoteItem.isPlayable)
        #expect(activeItems.count == 2)
        #expect(history.isEmpty)
    }

    @Test("remote removal preserves existing local eviction details")
    func remoteRemovalPreservesExistingLocalEvictionDetails() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)
        try PlaylistSyncService().reconcile(
            snapshots: [
                snapshot(id: "track-1", title: "First")
            ],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        let item = try #require(PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context).first)
        item.evictedAt = Date(timeIntervalSince1970: 150)
        item.evictionReason = .skipCount
        item.evictionSource = .playbackRule

        try PlaylistSyncService().reconcile(
            snapshots: [],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 200),
            in: context
        )

        #expect(item.evictedAt == Date(timeIntervalSince1970: 150))
        #expect(item.evictionReason == .skipCount)
        #expect(item.evictionSource == .playbackRule)
    }

    private func snapshot(id: String, title: String) -> TrackSnapshot {
        TrackSnapshot(
            id: id,
            catalogID: id,
            libraryID: id,
            playlistEntryID: "entry-\(id)",
            playlistID: "playlist-1",
            title: title,
            artistName: "Sample Artist",
            albumTitle: "Sample Album",
            artworkURLTemplate: nil,
            durationSeconds: 180
        )
    }
}
