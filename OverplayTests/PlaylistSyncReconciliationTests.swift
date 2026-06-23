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
        let musicPlaylistID = "playlist-\(UUID().uuidString)"
        let playlist = PlaylistRecord(
            musicPlaylistID: musicPlaylistID,
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)

        let summary = try PlaylistSyncService().reconcile(
            snapshots: [
                snapshot(id: "track-1", title: "First"),
                snapshot(id: "track-2", title: "Second")
            ],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )

        #expect(summary.fetchedCount == 2)
        #expect(summary.insertedCount == 2)
        #expect(summary.updatedCount == 0)
        #expect(summary.unchangedCount == 0)
        #expect(try TrackRecordRepository.allTracks(in: context).count == 2)
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        #expect(items.count == 2)
        #expect(summary.insertedLocalTrackIDs.count == 2)
        #expect(PlaybackOrderStore.state(
            playerID: "main",
            musicPlaylistID: musicPlaylistID
        ).orderedTrackIDs == summary.insertedLocalTrackIDs)
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

        let firstSummary = try PlaylistSyncService().reconcile(
            snapshots: snapshots,
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        let firstTrack = try #require(try TrackRecordRepository.track(musicItemID: "track-1", in: context))
        let firstItem = try #require(try PlaylistItemRepository.item(
            playlistID: playlist.id,
            trackID: firstTrack.id,
            in: context
        ))
        let trackUpdatedAt = firstTrack.updatedAt
        let itemUpdatedAt = firstItem.updatedAt
        let itemLastSeenInPlaylistAt = firstItem.lastSeenInPlaylistAt

        let secondSummary = try PlaylistSyncService().reconcile(
            snapshots: snapshots,
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 200),
            in: context
        )

        #expect(firstSummary.insertedCount == 2)
        #expect(secondSummary.fetchedCount == 2)
        #expect(secondSummary.insertedCount == 0)
        #expect(secondSummary.updatedCount == 0)
        #expect(secondSummary.unchangedCount == 2)
        #expect(try TrackRecordRepository.allTracks(in: context).count == 2)
        #expect(try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context).count == 2)
        #expect(firstTrack.updatedAt == trackUpdatedAt)
        #expect(firstItem.updatedAt == itemUpdatedAt)
        #expect(firstItem.lastSeenInPlaylistAt == itemLastSeenInPlaylistAt)
        #expect(playlist.lastSyncedAt == Date(timeIntervalSince1970: 200))
    }

    @Test("reconcile reports changed metadata and newly inserted tracks")
    func reconcileReportsChangedMetadataAndNewlyInsertedTracks() throws {
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
        let track = try #require(try TrackRecordRepository.track(musicItemID: "track-1", in: context))
        let item = try #require(try PlaylistItemRepository.item(
            playlistID: playlist.id,
            trackID: track.id,
            in: context
        ))
        let itemLastSeenInPlaylistAt = item.lastSeenInPlaylistAt

        let summary = try PlaylistSyncService().reconcile(
            snapshots: [
                snapshot(id: "track-1", title: "First Updated"),
                snapshot(id: "track-2", title: "Second")
            ],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 200),
            in: context
        )

        let updatedTrack = try #require(try TrackRecordRepository.track(musicItemID: "track-1", in: context))
        #expect(summary.fetchedCount == 2)
        #expect(summary.insertedCount == 1)
        #expect(summary.updatedCount == 1)
        #expect(summary.unchangedCount == 0)
        #expect(summary.artworkWarmupSnapshots.map(\.id) == ["track-1", "track-2"])
        #expect(updatedTrack.title == "First Updated")
        #expect(item.lastSeenInPlaylistAt == itemLastSeenInPlaylistAt)
    }

    @Test("reconcile ignores remote sort order changes")
    func reconcileIgnoresRemoteSortOrderChanges() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let musicPlaylistID = "playlist-\(UUID().uuidString)"
        let playlist = PlaylistRecord(
            musicPlaylistID: musicPlaylistID,
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
        let firstOrder = PlaybackOrderStore.state(
            playerID: "main",
            musicPlaylistID: musicPlaylistID
        ).orderedTrackIDs

        let summary = try PlaylistSyncService().reconcile(
            snapshots: [
                snapshot(id: "track-2", title: "Second"),
                snapshot(id: "track-1", title: "First")
            ],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 200),
            in: context
        )

        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        #expect(summary.fetchedCount == 2)
        #expect(summary.insertedCount == 0)
        #expect(summary.updatedCount == 0)
        #expect(summary.unchangedCount == 2)
        #expect(items.count == 2)
        #expect(PlaybackOrderStore.state(
            playerID: "main",
            musicPlaylistID: musicPlaylistID
        ).orderedTrackIDs == firstOrder)
        #expect(items.allSatisfy { $0.lastSeenInPlaylistAt != Date(timeIntervalSince1970: 200) })
    }

    @Test("reconcile collapses duplicate remote tracks")
    func reconcileCollapsesDuplicateRemoteTracks() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let musicPlaylistID = "playlist-\(UUID().uuidString)"
        let playlist = PlaylistRecord(
            musicPlaylistID: musicPlaylistID,
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)

        let summary = try PlaylistSyncService().reconcile(
            snapshots: [
                snapshot(id: "track-1", title: "First"),
                snapshot(id: "track-1", title: "First Duplicate"),
                snapshot(id: "track-2", title: "Second")
            ],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )

        #expect(summary.fetchedCount == 3)
        #expect(summary.insertedCount == 2)
        #expect(summary.skippedCount == 1)
        #expect(try TrackRecordRepository.allTracks(in: context).count == 2)
        #expect(try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context).count == 2)
        #expect(PlaybackOrderStore.state(
            playerID: "main",
            musicPlaylistID: musicPlaylistID
        ).orderedTrackIDs.count == 2)
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
