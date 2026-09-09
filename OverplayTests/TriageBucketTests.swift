import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Triage bucket")
struct TriageBucketTests {

    // MARK: - Sync fan-in

    @Test("two contributing playlists sharing a track produce one bucket row")
    func contributingPlaylistsSharingATrackProduceOneBucketRow() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let syncService = PlaylistSyncService()
        let firstSource = try PlaylistRepository.addTriageSource(
            AppleMusicPlaylist(id: "source-1", name: "Weekly", trackCount: 2),
            in: context
        )
        let secondSource = try PlaylistRepository.addTriageSource(
            AppleMusicPlaylist(id: "source-2", name: "Discovery", trackCount: 2),
            in: context
        )

        _ = try await syncService.reconcile(
            snapshots: [snapshot(id: "shared"), snapshot(id: "only-first")],
            playlistRecord: firstSource,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        _ = try await syncService.reconcile(
            snapshots: [snapshot(id: "shared"), snapshot(id: "only-second")],
            playlistRecord: secondSource,
            syncedAt: Date(timeIntervalSince1970: 200),
            in: context
        )

        let bucket = try #require(try PlaylistRepository.existingTriageBucket(in: context))
        let bucketItems = try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context)
        #expect(bucketItems.count == 3)
        // Contributing playlists own no items of their own.
        #expect(try PlaylistItemRepository.items(forPlaylistID: firstSource.id, in: context).isEmpty)
        #expect(try PlaylistItemRepository.items(forPlaylistID: secondSource.id, in: context).isEmpty)

        let sharedTrack = try #require(
            try TrackRecordRepository.track(catalogID: "shared", libraryID: "shared", in: context)
        )
        let sharedItem = try #require(bucketItems.first { $0.trackID == sharedTrack.id })
        #expect(sharedItem.sourceMusicPlaylistIDs == ["source-1", "source-2"])
    }

    @Test("an evicted bucket track stays evicted when a later playlist contributes it")
    func evictedBucketTrackStaysEvictedWhenLaterPlaylistContributesIt() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let syncService = PlaylistSyncService()
        let firstSource = try PlaylistRepository.addTriageSource(
            AppleMusicPlaylist(id: "source-1", name: "Weekly", trackCount: 1),
            in: context
        )
        _ = try await syncService.reconcile(
            snapshots: [snapshot(id: "unwanted")],
            playlistRecord: firstSource,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        let bucket = try #require(try PlaylistRepository.existingTriageBucket(in: context))
        let item = try #require(
            try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context).first
        )
        EvictionEngine.evict(item, playlist: bucket, context: context)
        try context.save()

        // The user adds another playlist that happens to contain the same
        // track. Their "no" must survive it.
        let secondSource = try PlaylistRepository.addTriageSource(
            AppleMusicPlaylist(id: "source-2", name: "Discovery", trackCount: 1),
            in: context
        )
        _ = try await syncService.reconcile(
            snapshots: [snapshot(id: "unwanted")],
            playlistRecord: secondSource,
            syncedAt: Date(timeIntervalSince1970: 200),
            in: context
        )

        let bucketItems = try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context)
        #expect(bucketItems.count == 1)
        #expect(bucketItems.first?.evictedAt != nil)
        #expect(bucketItems.first?.isPlayable == false)
    }

    @Test("syncing the bucket with no contributing playlists reports a skip, not an error")
    func syncingBucketWithoutContributingPlaylistsReportsSkip() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)

        let summary = try await PlaylistSyncService().syncPlaylist(bucket, in: context)

        // The reserved bucket identifier is not an Apple Music playlist, so
        // this must never become a fetch attempt.
        #expect(summary.fetchedCount == 0)
        #expect(summary.skippedReason == "noTriageSources")
        #expect(bucket.lastSyncError == nil)
    }

    // MARK: - Unlinking a contributor

    @Test("unlinking a contributing playlist keeps its tracks unattributed")
    func unlinkingContributingPlaylistKeepsTracksUnattributed() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let source = try PlaylistRepository.addTriageSource(
            AppleMusicPlaylist(id: "source-1", name: "Weekly", trackCount: 1),
            in: context
        )
        _ = try await PlaylistSyncService().reconcile(
            snapshots: [snapshot(id: "kept")],
            playlistRecord: source,
            syncedAt: Date(timeIntervalSince1970: 100),
            in: context
        )
        let bucket = try #require(try PlaylistRepository.existingTriageBucket(in: context))
        let item = try #require(
            try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context).first
        )
        item.skipCount = 4
        item.playthroughCount = 2

        try PlaylistRepository.removeTriageSource(source, in: context)

        let bucketItems = try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context)
        #expect(bucketItems.count == 1)
        // The row is the track's only row, so its history has to survive.
        #expect(bucketItems.first?.skipCount == 4)
        #expect(bucketItems.first?.playthroughCount == 2)
        #expect(bucketItems.first?.sourceMusicPlaylistIDs.isEmpty == true)
        #expect(source.isActive == false)
    }

    // MARK: - Promotion

    @Test("promotion works from the bucket and is refused from a contributing playlist")
    func promotionWorksFromBucketAndIsRefusedFromContributingPlaylist() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let oneTruePlaylist = PlaylistRecord(
            musicPlaylistID: "main",
            name: "Overplay",
            role: .oneTruePlaylist
        )
        context.insert(oneTruePlaylist)
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let source = try PlaylistRepository.addTriageSource(
            AppleMusicPlaylist(id: "source-1", name: "Weekly", trackCount: 1),
            in: context
        )
        let track = TrackRecord(catalogID: "track-1", title: "Song", artistName: "Artist")
        context.insert(track)
        let bucketItem = PlaylistItemRecord(playlistID: bucket.id, trackID: track.id, skipCount: 3)
        context.insert(bucketItem)
        let sourceItem = PlaylistItemRecord(playlistID: source.id, trackID: track.id)
        context.insert(sourceItem)

        let service = PlaylistMutationService()
        let promoted = try service.recordSuccessfulPromotion(
            sourceItem: bucketItem,
            sourcePlaylist: bucket,
            oneTruePlaylist: oneTruePlaylist,
            track: track,
            in: context
        )

        #expect(promoted.playlistID == oneTruePlaylist.id)
        #expect(bucketItem.evictedAt != nil)

        #expect(throws: PlaylistMutationError.self) {
            try service.recordSuccessfulPromotion(
                sourceItem: sourceItem,
                sourcePlaylist: source,
                oneTruePlaylist: oneTruePlaylist,
                track: track,
                in: context
            )
        }
    }

    // MARK: - Migration

    @Test("migration moves legacy triage items onto the bucket and merges duplicates")
    func migrationMovesLegacyTriageItemsOntoBucketAndMergesDuplicates() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (sharedTrack, onlyFirstTrack) = try insertLegacyTriageData(in: context)

        let outcome = try TriageBucketMigrationService.migrate(in: context, defaults: makeDefaults())

        #expect(outcome.migratedSourceCount == 2)
        #expect(outcome.movedItemCount == 2)
        #expect(outcome.mergedItemCount == 1)

        let bucket = try #require(try PlaylistRepository.existingTriageBucket(in: context))
        let bucketItems = try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context)
        #expect(bucketItems.count == 2)

        let sharedItem = try #require(bucketItems.first { $0.trackID == sharedTrack.id })
        // 3 + 4 skips and 1 + 2 playthroughs, so neither playlist's history is
        // the one that "won".
        #expect(sharedItem.skipCount == 7)
        #expect(sharedItem.playthroughCount == 3)
        // Migration walks playlists in display order, so which contributor
        // lands first is deliberate but not meaningful — both must be there.
        #expect(sharedItem.sourceMusicPlaylistIDs.sorted() == ["legacy-1", "legacy-2"])

        let onlyFirstItem = try #require(bucketItems.first { $0.trackID == onlyFirstTrack.id })
        #expect(onlyFirstItem.sourceMusicPlaylistIDs == ["legacy-1"])

        let sources = try PlaylistRepository.triageSources(in: context)
        #expect(sources.map(\.musicPlaylistID).sorted() == ["legacy-1", "legacy-2"])
        #expect(sources.allSatisfy { !$0.needsTriageBucketMigration })
    }

    @Test("migration is idempotent, so re-running never double-counts")
    func migrationIsIdempotent() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let (sharedTrack, _) = try insertLegacyTriageData(in: context)
        let defaults = makeDefaults()

        try TriageBucketMigrationService.migrate(in: context, defaults: defaults)
        let secondOutcome = try TriageBucketMigrationService.migrate(in: context, defaults: defaults)

        #expect(secondOutcome.didChangeAnything == false)
        let bucket = try #require(try PlaylistRepository.existingTriageBucket(in: context))
        let bucketItems = try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context)
        #expect(bucketItems.count == 2)
        let sharedItem = try #require(bucketItems.first { $0.trackID == sharedTrack.id })
        #expect(sharedItem.skipCount == 7)
        #expect(sharedItem.playthroughCount == 3)
        // Exactly one bucket, however many times this runs.
        #expect(try PlaylistRepository.allPlaylists(in: context).filter(\.isTriageBucket).count == 1)
    }

    @Test("migration preserves the most recent eviction decision")
    func migrationPreservesMostRecentEvictionDecision() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let track = TrackRecord(catalogID: "shared", title: "Shared", artistName: "Artist")
        context.insert(track)
        // The older active row is processed first. This catches migrations
        // that replace its decision timestamp with the migration time before
        // considering the newer evicted duplicate.
        let firstPlaylist = insertLegacyTriagePlaylist(musicPlaylistID: "legacy-1", name: "A First", in: context)
        let secondPlaylist = insertLegacyTriagePlaylist(musicPlaylistID: "legacy-2", name: "Z Second", in: context)
        let activeItem = PlaylistItemRecord(
            playlistID: firstPlaylist.id,
            trackID: track.id,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        context.insert(activeItem)
        let evictedItem = PlaylistItemRecord(
            playlistID: secondPlaylist.id,
            trackID: track.id,
            evictedAt: Date(timeIntervalSince1970: 200),
            evictionReason: .manual,
            evictionSource: .user,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        context.insert(evictedItem)

        try TriageBucketMigrationService.migrate(in: context, defaults: makeDefaults())

        let bucket = try #require(try PlaylistRepository.existingTriageBucket(in: context))
        let bucketItems = try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context)
        #expect(bucketItems.count == 1)
        #expect(bucketItems.first?.evictedAt == Date(timeIntervalSince1970: 200))
        #expect(bucketItems.first?.evictionReason == .manual)
    }

    @Test("migration rekeys the restore point that pointed at a migrated playlist")
    func migrationRekeysRestorePointForMigratedPlaylist() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        _ = try insertLegacyTriageData(in: context)
        let defaults = makeDefaults()
        LocalPlaybackStateStore.save(
            LocalPlaybackState(
                playlistID: "legacy-1",
                musicItemID: "shared",
                elapsedSeconds: 12,
                wasPlaying: false,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            to: defaults
        )

        try TriageBucketMigrationService.migrate(in: context, defaults: defaults)

        #expect(
            LocalPlaybackStateStore.load(from: defaults)?.playlistID
                == PlaylistRecord.triageBucketMusicPlaylistID
        )
    }

    @Test("migration leaves a One True Playlist restore point alone")
    func migrationLeavesOneTruePlaylistRestorePointAlone() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        _ = try insertLegacyTriageData(in: context)
        let defaults = makeDefaults()
        LocalPlaybackStateStore.save(
            LocalPlaybackState(
                playlistID: "main",
                musicItemID: "shared",
                elapsedSeconds: 12,
                wasPlaying: false,
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
            to: defaults
        )

        try TriageBucketMigrationService.migrate(in: context, defaults: defaults)

        #expect(LocalPlaybackStateStore.load(from: defaults)?.playlistID == "main")
    }

    @Test("migration creates the initial bucket when there is no legacy triage data")
    func migrationCreatesInitialBucketWithoutLegacyTriageData() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let oneTruePlaylist = PlaylistRecord(
            musicPlaylistID: "main",
            name: "Overplay",
            role: .oneTruePlaylist
        )
        context.insert(oneTruePlaylist)

        let outcome = try TriageBucketMigrationService.migrate(in: context, defaults: makeDefaults())

        #expect(outcome.createdBucket)
        #expect(outcome.didChangeAnything)
        let bucket = try #require(try PlaylistRepository.existingTriageBucket(in: context))
        #expect(bucket.isActive)
        #expect(bucket.role == .triageBucket)
    }

    // MARK: - Helpers

    /// Two pre-bucket triage playlists that share one track, so migration has
    /// both a move and a merge to do.
    private func insertLegacyTriageData(
        in context: ModelContext
    ) throws -> (sharedTrack: TrackRecord, onlyFirstTrack: TrackRecord) {
        let sharedTrack = TrackRecord(catalogID: "shared", title: "Shared", artistName: "Artist")
        let onlyFirstTrack = TrackRecord(catalogID: "only-first", title: "Only First", artistName: "Artist")
        context.insert(sharedTrack)
        context.insert(onlyFirstTrack)

        let firstPlaylist = insertLegacyTriagePlaylist(musicPlaylistID: "legacy-1", name: "Weekly", in: context)
        let secondPlaylist = insertLegacyTriagePlaylist(musicPlaylistID: "legacy-2", name: "Discovery", in: context)

        context.insert(PlaylistItemRecord(
            playlistID: firstPlaylist.id,
            trackID: sharedTrack.id,
            skipCount: 3,
            playthroughCount: 1
        ))
        context.insert(PlaylistItemRecord(
            playlistID: firstPlaylist.id,
            trackID: onlyFirstTrack.id
        ))
        context.insert(PlaylistItemRecord(
            playlistID: secondPlaylist.id,
            trackID: sharedTrack.id,
            skipCount: 4,
            playthroughCount: 2
        ))
        return (sharedTrack, onlyFirstTrack)
    }

    /// Writes the raw value a pre-bucket install actually stored, which is the
    /// only thing the migration can key on.
    private func insertLegacyTriagePlaylist(
        musicPlaylistID: String,
        name: String,
        in context: ModelContext
    ) -> PlaylistRecord {
        let playlist = PlaylistRecord(musicPlaylistID: musicPlaylistID, name: name)
        playlist.roleRawValue = PlaylistRole.legacyTriageRawValue
        context.insert(playlist)
        return playlist
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "overplay.tests.triage-bucket.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func snapshot(id: String) -> TrackSnapshot {
        TrackSnapshot(
            id: id,
            catalogID: id,
            libraryID: id,
            playlistEntryID: "entry-\(id)",
            playlistID: nil,
            title: id.capitalized,
            artistName: "Sample Artist",
            albumTitle: "Sample Album",
            artworkURLTemplate: nil,
            durationSeconds: 180
        )
    }
}
