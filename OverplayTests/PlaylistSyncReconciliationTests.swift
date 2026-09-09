import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Playlist sync reconciliation")
struct PlaylistSyncReconciliationTests {
    @Test("reconcile inserts tracks and playlist items")
    func reconcileInsertsTracksAndPlaylistItems() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let musicPlaylistID = "playlist-\(UUID().uuidString)"
        let playlist = PlaylistRecord(
            musicPlaylistID: musicPlaylistID,
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)

        let summary = try await PlaylistSyncService().reconcile(
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
    func repeatedReconcileDoesNotDuplicateTracksOrPlaylistItems() async throws {
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

        let firstSummary = try await PlaylistSyncService().reconcile(
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

        let secondSummary = try await PlaylistSyncService().reconcile(
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

    @Test("an unchanged item's lastSeenInPlaylistAt refreshes once the stamp is a day old")
    func anUnchangedItemsLastSeenInPlaylistAtRefreshesOnceTheStampIsADayOld() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)
        let snapshots = [snapshot(id: "track-1", title: "First")]
        let firstSync = Date(timeIntervalSince1970: 100)
        try await PlaylistSyncService().reconcile(
            snapshots: snapshots,
            playlistRecord: playlist,
            syncedAt: firstSync,
            in: context
        )

        let staleSync = firstSync.addingTimeInterval(PlaylistSyncService.lastSeenRefreshInterval + 1)
        try await PlaylistSyncService().reconcile(
            snapshots: snapshots,
            playlistRecord: playlist,
            syncedAt: staleSync,
            in: context
        )

        let track = try #require(try TrackRecordRepository.track(musicItemID: "track-1", in: context))
        let item = try #require(try PlaylistItemRepository.item(
            playlistID: playlist.id,
            trackID: track.id,
            in: context
        ))
        #expect(item.lastSeenInPlaylistAt == staleSync)
    }

    @Test("last-seen refresh rule stamps on change, first sighting, and a stale stamp")
    func lastSeenRefreshRuleStampsOnChangeFirstSightingAndAStaleStamp() {
        let syncedAt = Date(timeIntervalSince1970: 1_000_000)
        #expect(PlaylistSyncService.shouldRefreshLastSeen(current: nil, syncedAt: syncedAt, didChange: false))
        #expect(PlaylistSyncService.shouldRefreshLastSeen(
            current: syncedAt.addingTimeInterval(-10),
            syncedAt: syncedAt,
            didChange: true
        ))
        #expect(!PlaylistSyncService.shouldRefreshLastSeen(
            current: syncedAt.addingTimeInterval(-10),
            syncedAt: syncedAt,
            didChange: false
        ))
        #expect(PlaylistSyncService.shouldRefreshLastSeen(
            current: syncedAt.addingTimeInterval(-PlaylistSyncService.lastSeenRefreshInterval),
            syncedAt: syncedAt,
            didChange: false
        ))
    }

    @Test("reconcile reports changed metadata and newly inserted tracks")
    func reconcileReportsChangedMetadataAndNewlyInsertedTracks() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)
        try await PlaylistSyncService().reconcile(
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

        let summary = try await PlaylistSyncService().reconcile(
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
    func reconcileIgnoresRemoteSortOrderChanges() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let musicPlaylistID = "playlist-\(UUID().uuidString)"
        let playlist = PlaylistRecord(
            musicPlaylistID: musicPlaylistID,
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)
        try await PlaylistSyncService().reconcile(
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

        let summary = try await PlaylistSyncService().reconcile(
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
    func reconcileCollapsesDuplicateRemoteTracks() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let musicPlaylistID = "playlist-\(UUID().uuidString)"
        let playlist = PlaylistRecord(
            musicPlaylistID: musicPlaylistID,
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)

        let summary = try await PlaylistSyncService().reconcile(
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
    func reconcileRemoteRemovalsKeepsLocalItemPlayable() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)

        try await PlaylistSyncService().reconcile(
            snapshots: [
                snapshot(id: "track-1", title: "First"),
                snapshot(id: "track-2", title: "Second")
            ],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        try await PlaylistSyncService().reconcile(
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
    func remoteRemovalPreservesExistingLocalEvictionDetails() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let playlist = PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist
        )
        context.insert(playlist)
        try await PlaylistSyncService().reconcile(
            snapshots: [
                snapshot(id: "track-1", title: "First")
            ],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        let item = try #require(PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context).first)
        item.evictedAt = Date(timeIntervalSince1970: 150)
        item.evictionReason = .manual
        item.evictionSource = .user

        try await PlaylistSyncService().reconcile(
            snapshots: [],
            playlistRecord: playlist,
            syncedAt: Date(timeIntervalSince1970: 200),
            in: context
        )

        #expect(item.evictedAt == Date(timeIntervalSince1970: 150))
        #expect(item.evictionReason == .manual)
        #expect(item.evictionSource == .user)
    }

    @Test("unlinking during a remote fetch cannot restore source provenance")
    func unlinkingDuringRemoteFetchCannotRestoreSourceProvenance() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let source = try PlaylistRepository.addTriageSource(
            AppleMusicPlaylist(id: "source", name: "Source", trackCount: 1),
            in: context
        )
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let service = PlaylistSyncService()
        try await service.reconcile(
            snapshots: [snapshot(id: "track-1", title: "First")],
            playlistRecord: source,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        let item = try #require(PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context).first)
        #expect(item.sourceMusicPlaylistIDs == [source.musicPlaylistID])

        let deferredSource = DeferredPlaylistSourceSync()
        let deferredService = PlaylistSyncService(
            sourceRegistry: PlaylistSourceSyncRegistry(adapters: [.appleMusic: deferredSource])
        )
        let syncTask = Task {
            try await deferredService.syncPlaylist(source, in: context)
        }
        await deferredSource.waitUntilFetchStarts()

        try PlaylistRepository.removeTriageSource(source, in: context)
        deferredSource.completeFetch(
            with: PlaylistSourceFetchResult(
                snapshots: [snapshot(id: "track-1", title: "First")],
                skippedCount: 0,
                skippedReason: nil,
                remoteLastModifiedAt: nil
            )
        )
        let summary = try await syncTask.value

        #expect(summary.skippedReason == "inactivePlaylist")
        #expect(!source.isActive)
        #expect(item.sourceMusicPlaylistIDs.isEmpty)
    }

    @Test("demoting a playlist between sync chunks sends remaining rows to the bucket")
    func demotingPlaylistBetweenSyncChunksSendsRemainingRowsToBucket() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let originalPlaylistID = "original-\(UUID().uuidString)"
        let replacementPlaylistID = "replacement-\(UUID().uuidString)"
        let original = try PlaylistRepository.setOneTruePlaylist(
            AppleMusicPlaylist(id: originalPlaylistID, name: "Original", trackCount: nil),
            in: context
        )
        let snapshots = (0...PlaylistSyncService.syncYieldStride).map { index in
            snapshot(id: "track-\(index)-\(UUID().uuidString)", title: "Track \(index)")
        }
        PlaybackOrderStore.clear(
            playerID: "main",
            musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
            flushImmediately: true
        )
        defer {
            PlaybackOrderStore.clear(
                playerID: "main",
                musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
                flushImmediately: true
            )
        }

        var didDemote = false
        let service = PlaylistSyncService(yieldDuringReconciliation: {
            guard !didDemote else { return }
            didDemote = true
            _ = try PlaylistRepository.setOneTruePlaylist(
                AppleMusicPlaylist(id: replacementPlaylistID, name: "Replacement", trackCount: nil),
                in: context
            )
        })

        let summary = try await service.reconcile(
            snapshots: snapshots,
            playlistRecord: original,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )

        let bucket = try PlaylistRepository.triageBucket(in: context)
        let bucketItems = try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context)
        #expect(didDemote)
        #expect(original.role == .triageSource)
        #expect(try PlaylistItemRepository.items(forPlaylistID: original.id, in: context).isEmpty)
        #expect(bucketItems.count == snapshots.count)
        #expect(bucketItems.allSatisfy {
            $0.sourceMusicPlaylistIDs == [originalPlaylistID]
        })
        #expect(summary.insertedCount == snapshots.count)
        #expect(Set(PlaybackOrderStore.state(
            playerID: "main",
            musicPlaylistID: bucket.musicPlaylistID
        ).orderedTrackIDs) == Set(summary.insertedLocalTrackIDs))
    }

    @Test("promoting a source between sync chunks replays earlier rows into the new main")
    func promotingSourceBetweenSyncChunksReplaysEarlierRowsIntoNewMain() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let sourcePlaylistID = "source-\(UUID().uuidString)"
        let source = try PlaylistRepository.addTriageSource(
            AppleMusicPlaylist(id: sourcePlaylistID, name: "Source", trackCount: nil),
            in: context
        )
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let snapshots = (0...PlaylistSyncService.syncYieldStride).map { index in
            snapshot(id: "track-\(index)-\(UUID().uuidString)", title: "Track \(index)")
        }
        for musicPlaylistID in [sourcePlaylistID, bucket.musicPlaylistID] {
            PlaybackOrderStore.clear(
                playerID: "main",
                musicPlaylistID: musicPlaylistID,
                flushImmediately: true
            )
        }
        defer {
            for musicPlaylistID in [sourcePlaylistID, bucket.musicPlaylistID] {
                PlaybackOrderStore.clear(
                    playerID: "main",
                    musicPlaylistID: musicPlaylistID,
                    flushImmediately: true
                )
            }
        }

        var didPromote = false
        let service = PlaylistSyncService(yieldDuringReconciliation: {
            guard !didPromote else { return }
            didPromote = true
            _ = try PlaylistRepository.setOneTruePlaylist(
                AppleMusicPlaylist(id: sourcePlaylistID, name: "Source", trackCount: nil),
                in: context
            )
        })

        let summary = try await service.reconcile(
            snapshots: snapshots,
            playlistRecord: source,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )

        let mainItems = try PlaylistItemRepository.items(forPlaylistID: source.id, in: context)
        let bucketItems = try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context)
        #expect(didPromote)
        #expect(source.role == .oneTruePlaylist)
        #expect(mainItems.count == snapshots.count)
        #expect(bucketItems.count == PlaylistSyncService.syncYieldStride)
        #expect(bucketItems.allSatisfy {
            $0.sourceMusicPlaylistIDs == [sourcePlaylistID]
        })
        #expect(summary.insertedCount == snapshots.count)
        #expect(Set(PlaybackOrderStore.state(
            playerID: "main",
            musicPlaylistID: sourcePlaylistID
        ).orderedTrackIDs) == Set(mainItems.map { $0.trackID.uuidString }))
        #expect(Set(PlaybackOrderStore.state(
            playerID: "main",
            musicPlaylistID: bucket.musicPlaylistID
        ).orderedTrackIDs) == Set(bucketItems.map { $0.trackID.uuidString }))
    }

    @Test("healing a source playlist ID also heals provenance used by unlink")
    func healingSourcePlaylistIDAlsoHealsProvenanceUsedByUnlink() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let source = try PlaylistRepository.addTriageSource(
            AppleMusicPlaylist(id: "source.old", name: "Source", trackCount: 1),
            in: context
        )
        let bucket = try PlaylistRepository.triageBucket(in: context)
        try await PlaylistSyncService().reconcile(
            snapshots: [snapshot(id: "track-1", title: "First")],
            playlistRecord: source,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        let item = try #require(PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context).first)

        try AppleMusicPlaylistSourceSync().applyHealedMusicPlaylistID(
            from: "source.old",
            to: "source.new",
            playlistRecord: source,
            in: context
        )

        #expect(source.musicPlaylistID == "source.new")
        #expect(item.sourceMusicPlaylistIDs == ["source.new"])

        try PlaylistRepository.removeTriageSource(source, in: context)
        #expect(item.sourceMusicPlaylistIDs.isEmpty)
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

@MainActor
private final class DeferredPlaylistSourceSync: PlaylistSourceSyncing {
    let source: PlaylistSource = .appleMusic

    private var fetchContinuation: CheckedContinuation<PlaylistSourceFetchResult, Never>?
    private var fetchStartWaiters: [CheckedContinuation<Void, Never>] = []

    func fetchLibraryPlaylists() async throws -> [RemotePlaylistLink] {
        []
    }

    func fetchTrackSnapshots(
        playlistID: String,
        playlistName: String?,
        playlistRecord: PlaylistRecord?,
        skipWhenRemoteUnchanged: Bool,
        in context: ModelContext
    ) async throws -> PlaylistSourceFetchResult {
        for waiter in fetchStartWaiters {
            waiter.resume()
        }
        fetchStartWaiters.removeAll()

        return await withCheckedContinuation { continuation in
            fetchContinuation = continuation
        }
    }

    func waitUntilFetchStarts() async {
        guard fetchContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            fetchStartWaiters.append(continuation)
        }
    }

    func completeFetch(with result: PlaylistSourceFetchResult) {
        fetchContinuation?.resume(returning: result)
        fetchContinuation = nil
    }
}
