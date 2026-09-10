import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
struct GlobalTrackOwnershipTests {
    @Test("Retention distinguishes explicit active intent, reset history, and disposable retirement")
    func retentionTable() {
        let item = PlaylistItemRecord(playlistID: UUID(), trackID: UUID())
        #expect(TrackRetentionPolicy.shouldDelete(item))
        item.isExplicitlyKept = true
        #expect(!TrackRetentionPolicy.shouldDelete(item))
        item.evictedAt = .now
        #expect(TrackRetentionPolicy.shouldDelete(item))
        item.isExplicitlyKept = false
        item.evictedAt = nil
        item.lastSkippedAt = .now
        #expect(!TrackRetentionPolicy.shouldDelete(item))
        #expect(TrackRetentionPolicy.shouldDelete(item, legacyCleanup: true))
        item.evictedAt = .now
        #expect(TrackRetentionPolicy.shouldDelete(item))
        item.playthroughCount = 1
        #expect(!TrackRetentionPolicy.shouldDelete(item))
        item.playthroughCount = 0
        item.sourceMusicPlaylistIDs = ["source"]
        #expect(!TrackRetentionPolicy.shouldDelete(item))
        item.sourceMusicPlaylistIDs = []
        item.suppressedOTPMusicPlaylistIDs = ["otp"]
        #expect(!TrackRetentionPolicy.shouldDelete(item))
    }

    @Test("Promotion moves the same row with counts, provenance, and keep intent")
    func promotionMovesRatherThanCopies() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let otp = PlaylistRecord(musicPlaylistID: "otp", name: "OTP", role: .oneTruePlaylist)
        let track = TrackRecord(catalogID: "song", title: "Song", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: bucket.id, trackID: track.id,
                                      sourceMusicPlaylistIDs: ["source"], isExplicitlyKept: true,
                                      skipCount: 3, playthroughCount: 7)
        context.insert(otp)
        context.insert(track)
        context.insert(item)
        try context.save()
        let promoted = try PlaylistMutationService().recordSuccessfulPromotion(
            sourceItem: item, sourcePlaylist: bucket, oneTruePlaylist: otp, track: track, in: context
        )
        #expect(promoted.id == item.id)
        #expect(promoted.playlistID == otp.id)
        #expect(promoted.skipCount == 3 && promoted.playthroughCount == 7)
        #expect(promoted.isExplicitlyKept)
        #expect(promoted.sourceMusicPlaylistIDs == ["source"])
        #expect(try PlaylistItemRepository.allItems(in: context).count == 1)
        let intake = try PlaylistItemRepository.upsert(playlistID: bucket.id, trackID: track.id, in: context)
        #expect(intake.id == item.id && intake.playlistID == otp.id)
    }

    @Test("Both origins retire globally and moving to Triage establishes keep intent")
    func retireAndRestore() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let otp = PlaylistRecord(musicPlaylistID: "otp", name: "OTP", role: .oneTruePlaylist)
        context.insert(otp)
        let item = PlaylistItemRecord(playlistID: otp.id, trackID: UUID(), skipCount: 2)
        context.insert(item)
        try TrackActionService.evictTrack(item, playlist: otp, message: "Retired", in: context)
        #expect(item.playlistID == bucket.id && item.evictedAt != nil)
        #expect(item.suppressedOTPMusicPlaylistIDs == ["otp"])
        try TrackActionService.restoreTrack(item, playlist: bucket, in: context)
        #expect(item.playlistID == bucket.id && item.evictedAt == nil)
        #expect(item.skipCount == 2 && item.isExplicitlyKept)
        #expect(item.suppressedOTPMusicPlaylistIDs == ["otp"])
    }

    @Test("Unlink deletes only after the last source; retired manual 0/0 deletes immediately")
    func unlinkAndImmediateRetiredDeletion() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let first = try PlaylistRepository.addTriageSource(AppleMusicPlaylist(id: "a", name: "A", trackCount: nil), in: context)
        let second = try PlaylistRepository.addTriageSource(AppleMusicPlaylist(id: "b", name: "B", trackCount: nil), in: context)
        let shared = PlaylistItemRecord(playlistID: bucket.id, trackID: UUID(), sourceMusicPlaylistIDs: ["a", "b"])
        let kept = PlaylistItemRecord(playlistID: bucket.id, trackID: UUID(), sourceMusicPlaylistIDs: ["b"], isExplicitlyKept: true)
        let reset = PlaylistItemRecord(playlistID: bucket.id, trackID: UUID(), sourceMusicPlaylistIDs: ["b"], lastSkippedAt: .now)
        context.insert(shared)
        context.insert(kept)
        context.insert(reset)
        let sharedID = shared.id
        try PlaylistRepository.removeTriageSource(first, in: context)
        #expect(shared.sourceMusicPlaylistIDs == ["b"])
        try PlaylistRepository.removeTriageSource(second, in: context)
        #expect(try PlaylistItemRepository.item(id: sharedID, in: context) == nil)
        #expect(try PlaylistItemRepository.item(id: kept.id, in: context) != nil)
        #expect(try PlaylistItemRepository.item(id: reset.id, in: context) != nil)
        let keptID = kept.id
        try TrackActionService.evictTrack(kept, playlist: bucket, message: "Done", in: context)
        #expect(try PlaylistItemRepository.item(id: keptID, in: context) == nil)
        try TrackActionService.evictTrack(reset, playlist: bucket, message: "Done", in: context)
        #expect(try PlaylistItemRepository.allItems(in: context).isEmpty)
    }

    @Test("A source link revives only retirements older than that explicit link")
    func linkRevivalAndOrdinarySync() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let source = try PlaylistRepository.addTriageSource(AppleMusicPlaylist(id: "a", name: "A", trackCount: nil), in: context)
        source.triageLinkedAt = Date(timeIntervalSince1970: 200)
        let track = TrackRecord(catalogID: "song", title: "Song", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: bucket.id, trackID: track.id,
                                      skipCount: 3, evictedAt: Date(timeIntervalSince1970: 100))
        context.insert(track)
        context.insert(item)
        let snapshots = [snapshot("song")]
        let sync = PlaylistSyncService()
        _ = try await sync.reconcile(snapshots: snapshots, playlistRecord: source, syncedAt: Date(timeIntervalSince1970: 250), in: context)
        #expect(item.evictedAt == nil && item.skipCount == 3)
        item.evictedAt = Date(timeIntervalSince1970: 300)
        _ = try await sync.reconcile(snapshots: snapshots, playlistRecord: source, syncedAt: Date(timeIntervalSince1970: 400), in: context)
        #expect(item.evictedAt == Date(timeIntervalSince1970: 300))
        try PlaylistRepository.removeTriageSource(source, in: context)
        _ = try PlaylistRepository.addTriageSource(AppleMusicPlaylist(id: "a", name: "A", trackCount: nil), in: context)
        _ = try await sync.reconcile(snapshots: snapshots, playlistRecord: source, syncedAt: .now, in: context)
        #expect(item.evictedAt == nil && item.skipCount == 3)
    }

    @Test("Stale OTP cannot resurrect a retired or explicitly restored song; proven absence releases suppression")
    func staleOTPProtection() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let otp = PlaylistRecord(musicPlaylistID: "otp", name: "OTP", role: .oneTruePlaylist)
        let track = TrackRecord(catalogID: "song", title: "Song", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: otp.id, trackID: track.id)
        context.insert(otp)
        context.insert(track)
        context.insert(item)
        try TrackActionService.evictTrack(item, playlist: otp, message: "Retired", in: context)
        let sync = PlaylistSyncService()
        _ = try await sync.reconcile(snapshots: [snapshot("song")], playlistRecord: otp, syncedAt: .now, in: context)
        #expect(item.playlistID == bucket.id && item.evictedAt != nil)
        try TrackActionService.restoreTrack(item, playlist: bucket, in: context)
        _ = try await sync.reconcile(snapshots: [snapshot("song")], playlistRecord: otp, syncedAt: .now, in: context)
        #expect(item.playlistID == bucket.id && item.evictedAt == nil)
        _ = try await sync.reconcile(snapshots: [], playlistRecord: otp, syncedAt: .now, in: context)
        #expect(item.suppressedOTPMusicPlaylistIDs.isEmpty)
        item.skipCount = 2
        _ = try await sync.reconcile(snapshots: [snapshot("song")], playlistRecord: otp, syncedAt: .now, in: context)
        #expect(item.playlistID == otp.id && item.skipCount == 2)
        let events = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(events.contains { $0.eventType == .promoted && $0.source == .sync })
    }

    @Test("Historical cleanup merges first, forgets legacy resets, and never repeats against new rows")
    func migrationIsOrderedAndIdempotent() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let otp = PlaylistRecord(musicPlaylistID: "otp", name: "OTP", role: .oneTruePlaylist)
        context.insert(otp)
        let sharedID = UUID()
        let main = PlaylistItemRecord(playlistID: otp.id, trackID: sharedID, ownershipVersion: 0, playthroughCount: 5)
        let duplicate = PlaylistItemRecord(playlistID: bucket.id, trackID: sharedID, ownershipVersion: 0, skipCount: 3)
        let forgotten = PlaylistItemRecord(playlistID: bucket.id, trackID: UUID(), ownershipVersion: 0, lastSkippedAt: .now)
        let modernReset = PlaylistItemRecord(playlistID: bucket.id, trackID: UUID(), lastSkippedAt: .now)
        context.insert(main)
        context.insert(duplicate)
        context.insert(forgotten)
        context.insert(modernReset)
        let forgottenID = forgotten.id
        let first = try TrackOwnershipMigrationService.migrate(in: context)
        #expect(first.mergedCount == 1 && first.deletedCount == 1)
        let merged = try #require(try PlaylistItemRepository.item(trackID: sharedID, in: context))
        #expect(merged.playlistID == otp.id && merged.skipCount == 3 && merged.playthroughCount == 5)
        #expect(try PlaylistItemRepository.item(id: forgottenID, in: context) == nil)
        #expect(try PlaylistItemRepository.item(id: modernReset.id, in: context) != nil)
        let second = try TrackOwnershipMigrationService.migrate(in: context)
        #expect(second == .init())
        #expect(merged.skipCount == 3 && merged.playthroughCount == 5)
    }

    @Test("Retired auditions record skips and playthroughs without restoration")
    func retiredListeningCounts() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let item = PlaylistItemRecord(playlistID: bucket.id, trackID: UUID(), sourceMusicPlaylistIDs: ["source"], evictedAt: .now)
        context.insert(item)
        let session = TrackPlaySession(trackID: "song", sessionStartDate: .now,
                                       lastObservedPlaybackTime: 30, listenedSeconds: 30,
                                       durationSeconds: 200, hasEvaluated: false)
        EvictionEngine.evaluateSkip(item: item, playlist: bucket, session: session,
                                   transitionWasNaturalCompletion: false, settings: OverplaySettings(), context: context)
        EvictionEngine.countPlaythrough(item, playlist: bucket, session: session, settings: OverplaySettings(), context: context)
        #expect(item.skipCount == 1 && item.playthroughCount == 1)
        #expect(item.evictedAt != nil && item.hasRecordedActivity)
    }

    @Test("A later location decision supersedes an in-flight promotion")
    func laterMoveWinsPromotionRace() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let otp = PlaylistRecord(musicPlaylistID: "otp", name: "OTP", role: .oneTruePlaylist)
        let track = TrackRecord(catalogID: "song", title: "Song", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: bucket.id, trackID: track.id, isExplicitlyKept: true)
        context.insert(otp)
        context.insert(track)
        context.insert(item)
        let mutation = PlaylistMutationService(addRemotely: { _, _, context in
            // It returns to active Triage, so testing only evictedAt would
            // miss the user's newer destination choice.
            try TrackActionService.evictTrack(item, playlist: bucket, message: "Retired", in: context)
            try TrackActionService.restoreTrack(item, playlist: bucket, in: context)
        })
        await #expect(throws: PlaylistMutationError.self) {
            _ = try await mutation.promote(item: item, in: context)
        }
        #expect(item.playlistID == bucket.id && item.evictedAt == nil)
        #expect(item.suppressedOTPMusicPlaylistIDs == ["otp"])
        #expect(try PlaylistItemRepository.allItems(in: context).count == 1)
    }

    @Test("Legacy active OTP wins an old retired duplicate; newer explicit retirement wins late legacy delivery")
    func migrationLocationPrecedence() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let otp = PlaylistRecord(musicPlaylistID: "otp", name: "OTP", role: .oneTruePlaylist)
        context.insert(otp)
        let trackID = UUID()
        context.insert(PlaylistItemRecord(playlistID: otp.id, trackID: trackID, ownershipVersion: 0, skipCount: 2))
        context.insert(PlaylistItemRecord(playlistID: otp.id, trackID: trackID, ownershipVersion: 0, playthroughCount: 3, evictedAt: .now))
        try TrackOwnershipMigrationService.migrate(in: context)
        let item = try #require(try PlaylistItemRepository.item(trackID: trackID, in: context))
        #expect(item.playlistID == otp.id && item.evictedAt == nil)
        #expect(item.skipCount == 2 && item.playthroughCount == 3)
        #expect(item.suppressedOTPMusicPlaylistIDs.isEmpty)
        try TrackActionService.evictTrack(item, playlist: otp, message: "Retired", in: context)
        context.insert(PlaylistItemRecord(playlistID: otp.id, trackID: trackID, ownershipVersion: 0, skipCount: 1))
        try TrackOwnershipMigrationService.migrate(in: context)
        #expect(item.evictedAt != nil && item.skipCount == 3)
        #expect(item.playthroughCount == 3 && item.suppressedOTPMusicPlaylistIDs == ["otp"])
    }

    @Test("Resetting the last retired skip deletes an unowned row, but active reset history survives")
    func resetCleanup() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let item = PlaylistItemRecord(playlistID: bucket.id, trackID: UUID(), skipCount: 1)
        context.insert(item)
        try TrackActionService.resetSkipCount(item, playlist: bucket, message: "Reset", in: context)
        #expect(item.hasRecordedActivity && !TrackRetentionPolicy.shouldDelete(item))
        item.skipCount = 1
        try TrackActionService.evictTrack(item, playlist: bucket, message: "Retired", in: context)
        let itemID = item.id
        try TrackActionService.resetSkipCount(item, playlist: bucket, message: "Reset", in: context)
        #expect(try PlaylistItemRepository.item(id: itemID, in: context) == nil)
    }

    @Test("Every cleanup path defers a live session, then releases a retired 0/0 item")
    func backgroundCleanupHonorsPlaybackLease() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let item = PlaylistItemRecord(playlistID: bucket.id, trackID: UUID(), evictedAt: .now)
        context.insert(item)
        let itemID = item.id
        let lease = TrackRetentionPolicy.makePlaybackLease()
        lease.itemID = itemID
        #expect(try !TrackRetentionPolicy.deleteIfUnowned(item, in: context))
        #expect(item.pendingRetentionCleanup)
        lease.itemID = nil
        try TrackOwnershipMigrationService.migrate(in: context)
        #expect(try PlaylistItemRepository.item(id: itemID, in: context) == nil)
    }

    @Test("Legacy retired orders merge idempotently without replacing the destination")
    func retiredOrderMigration() throws {
        let defaults = try #require(UserDefaults(suiteName: "ownership-order-\(UUID().uuidString)"))
        PlaybackOrderStore.save(.init(playerID: "player", musicPlaylistID: "old", orderedTrackIDs: ["a", "b"]), to: defaults)
        PlaybackOrderStore.save(.init(playerID: "player", musicPlaylistID: "new", orderedTrackIDs: ["b", "c"]), to: defaults)
        PlaybackOrderStore.mergeMusicPlaylistID(from: "old", to: "new", from: defaults)
        PlaybackOrderStore.mergeMusicPlaylistID(from: "old", to: "new", from: defaults)
        #expect(PlaybackOrderStore.state(playerID: "player", musicPlaylistID: "new", from: defaults).orderedTrackIDs == ["b", "c", "a"])
        #expect(PlaybackOrderStore.state(playerID: "player", musicPlaylistID: "old", from: defaults).orderedTrackIDs.isEmpty)
    }

    @Test("Bucket pairwise convergence retains newer location intent despite a later metadata refresh")
    func pairwiseMergePreservesLocationIntent() {
        let keeper = PlaylistItemRecord(playlistID: UUID(), trackID: UUID(), updatedAt: Date(timeIntervalSince1970: 500))
        keeper.locationChangedAt = Date(timeIntervalSince1970: 100)
        let donor = PlaylistItemRecord(playlistID: keeper.playlistID, trackID: keeper.trackID, skipCount: 2,
                                      evictedAt: Date(timeIntervalSince1970: 200), updatedAt: Date(timeIntervalSince1970: 200))
        donor.locationChangedAt = Date(timeIntervalSince1970: 200)
        PlaylistItemRepository.mergeStats(from: donor, into: keeper, adoptEvictionStateIfNewer: true)
        #expect(keeper.evictedAt == donor.evictedAt)
        #expect(keeper.locationChangedAt == donor.locationChangedAt)
        #expect(keeper.skipCount == 2)
    }

    @Test("History page loads a moved item by track identity rather than its event's original playlist")
    func historyLoadsMovedItem() throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let otp = PlaylistRecord(musicPlaylistID: "history-otp", name: "OTP", role: .oneTruePlaylist)
        let track = TrackRecord(title: "Song", artistName: "Artist")
        let item = PlaylistItemRecord(playlistID: otp.id, trackID: track.id, skipCount: 1)
        context.insert(otp)
        context.insert(track)
        context.insert(item)
        try TrackActionService.evictTrack(item, playlist: otp, message: "Done", in: context)
        let events = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(events.first?.playlistID == otp.id)
        let loaded = try PlaylistItemRepository.items(forTrackIDs: events.compactMap(\.trackID), in: context)
        let model = HistoryViewModel()
        let row = try #require(model.rows(events: events, playlists: [otp], tracks: [track]).first)
        #expect(model.restorableItem(for: row, playlistItems: loaded)?.playlistID == bucket.id)
        item.skipCount = 0
        item.suppressedOTPMusicPlaylistIDs = []
        try TrackRetentionPolicy.deleteIfUnowned(item, in: context)
        try context.save()
        let afterDeletion = try PlaylistItemRepository.items(forTrackIDs: [track.id], in: context)
        #expect(model.restorableItem(for: row, playlistItems: afterDeletion) == nil)
    }

    private func snapshot(_ id: String) -> TrackSnapshot {
        TrackSnapshot(id: id, catalogID: id, libraryID: nil, playlistEntryID: nil,
                      playlistID: nil, title: "Song", artistName: "Artist", albumTitle: nil,
                      artworkURLTemplate: nil, durationSeconds: 200)
    }
}
