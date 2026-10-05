import Foundation
import SwiftData
import Testing
@testable import Overplay

/// `LOC-001`: a stale CloudKit write from another device must not undo a
/// retirement or restore. Observed on 2026-10-05: a Mac that had not imported
/// five iPhone retirements re-saved those rows and the iPhone imported them.
@MainActor
@Suite("Track location repair")
struct TrackLocationRepairTests {
    private struct Fixture {
        /// Held so SwiftData does not destroy the models mid-test.
        let container: ModelContainer
        let context: ModelContext
        let bucket: PlaylistRecord
        let otp: PlaylistRecord
        let item: PlaylistItemRecord
    }

    private func fixture(skipCount: Int = 2) throws -> Fixture {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let otp = PlaylistRecord(musicPlaylistID: "otp", name: "OTP", role: .oneTruePlaylist)
        context.insert(otp)
        let item = PlaylistItemRecord(playlistID: otp.id, trackID: UUID(), skipCount: skipCount)
        context.insert(item)
        try context.save()
        return Fixture(container: container, context: context, bucket: bucket, otp: otp, item: item)
    }

    /// What the importing device sees: the other device's row from before the move.
    private func overwriteWithStaleActiveOTPRow(_ item: PlaylistItemRecord, otp: PlaylistRecord) {
        item.playlistID = otp.id
        item.evictedAt = nil
        item.evictionReason = nil
        item.evictionSource = nil
        item.suppressedOTPMusicPlaylistIDs = []
        item.locationChangedAt = nil
    }

    private func newestEvent(_ type: HistoryEventType, for item: PlaylistItemRecord, in context: ModelContext) throws -> HistoryEvent {
        let raw = type.rawValue
        let trackID = item.trackID
        var descriptor = FetchDescriptor<HistoryEvent>(
            predicate: #Predicate { $0.eventTypeRawValue == raw && $0.trackID == trackID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try #require(try context.fetch(descriptor).first)
    }

    @Test("An overwritten retirement is re-applied from its history event, once")
    func reappliesOverwrittenRetirement() throws {
        let f = try fixture()
        try TrackActionService.evictTrack(f.item, playlist: f.otp, message: "Retired manually", in: f.context)
        let retiredAt = try newestEvent(.evicted, for: f.item, in: f.context).createdAt
        overwriteWithStaleActiveOTPRow(f.item, otp: f.otp)

        #expect(try TrackLocationService.repairRetirementState(in: f.context) == 1)
        #expect(f.item.playlistID == f.bucket.id)
        #expect(f.item.evictedAt == retiredAt)
        #expect(f.item.evictionSource == .user)
        #expect(f.item.suppressedOTPMusicPlaylistIDs == ["otp"])
        #expect(f.item.locationChangedAt == retiredAt)
        #expect(try TrackLocationService.repairRetirementState(in: f.context) == 0)
    }

    @Test("A repaired 0/0 One True Playlist retirement is deleted by the next complete sync without it")
    func repairedZeroZeroRetirementIsPurgedBySync() async throws {
        let f = try fixture(skipCount: 0)
        try TrackActionService.evictTrack(f.item, playlist: f.otp, message: "Retired manually", in: f.context)
        overwriteWithStaleActiveOTPRow(f.item, otp: f.otp)
        try TrackLocationService.repairRetirementState(in: f.context)
        // Suppression protects it while the song may still be in Apple Music.
        #expect(!f.item.isDeleted && f.item.evictedAt != nil)

        _ = try await PlaylistSyncService().reconcile(
            snapshots: [], playlistRecord: f.otp, syncedAt: .now, in: f.context
        )
        #expect(try PlaylistItemRepository.allItems(in: f.context).isEmpty)
    }

    @Test("An overwritten restore is re-applied: the row returns to active Triage")
    func reappliesOverwrittenRestore() throws {
        let f = try fixture()
        try TrackActionService.evictTrack(f.item, playlist: f.otp, message: "Retired manually", in: f.context)
        try TrackActionService.restoreTrack(f.item, playlist: f.bucket, in: f.context)
        let restoredAt = try newestEvent(.restored, for: f.item, in: f.context).createdAt
        // The stale row still says retired.
        f.item.evictedAt = Date(timeIntervalSince1970: 1)
        f.item.locationChangedAt = Date(timeIntervalSince1970: 1)

        #expect(try TrackLocationService.repairRetirementState(in: f.context) == 1)
        #expect(f.item.playlistID == f.bucket.id)
        #expect(f.item.evictedAt == nil)
        #expect(f.item.locationChangedAt == restoredAt)
    }

    @Test("Resetting all statistics un-retires and is not reverted by the older retirement")
    func resetAllStatsIsNotReverted() throws {
        let f = try fixture()
        try TrackActionService.evictTrack(f.item, playlist: f.otp, message: "Retired manually", in: f.context)
        try PlaylistItemRepository.resetAllStats(in: f.context)
        #expect(f.item.evictedAt == nil)

        #expect(try TrackLocationService.repairRetirementState(in: f.context) == 0)
        #expect(f.item.evictedAt == nil)
    }

    @Test("A row whose newest event is a promotion is left to the next sync")
    func promotionIsLeftAlone() throws {
        let f = try fixture()
        f.item.playlistID = f.bucket.id
        TrackLocationService.moveToOTP(f.item, playlist: f.otp, source: .user, in: f.context)
        // Stale row: back in Triage, from before the promotion.
        f.item.playlistID = f.bucket.id
        f.item.locationChangedAt = nil

        #expect(try TrackLocationService.repairRetirementState(in: f.context) == 0)
        #expect(f.item.playlistID == f.bucket.id)
    }

    @Test("A move newer than the newest event is not reverted")
    func newerMoveWins() throws {
        let f = try fixture()
        try TrackActionService.evictTrack(f.item, playlist: f.otp, message: "Retired manually", in: f.context)
        // A later move that wrote no event, e.g. on another device.
        f.item.evictedAt = nil
        f.item.locationChangedAt = Date.now.addingTimeInterval(60)

        #expect(try TrackLocationService.repairRetirementState(in: f.context) == 0)
        #expect(f.item.evictedAt == nil)
    }
}
