import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Periodic playlist sync service")
struct PeriodicPlaylistSyncServiceTests {
    @Test("recent successful playlists are skipped")
    func recentSuccessfulPlaylistsAreSkipped() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_000)
        let playlist = playlist(lastSyncedAt: now.addingTimeInterval(-60), lastSyncError: nil)
        context.insert(playlist)
        let recorder = SyncRecorder()
        let service = makeService(recorder: recorder)

        await service.syncLinkedPlaylists(context: context, now: now)

        #expect(recorder.syncedIDs.isEmpty)
    }

    @Test("stale successful playlists are synced")
    func staleSuccessfulPlaylistsAreSynced() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 3_000)
        let playlist = playlist(lastSyncedAt: now.addingTimeInterval(-(30 * 60 + 1)), lastSyncError: nil)
        context.insert(playlist)
        let recorder = SyncRecorder()
        let service = makeService(recorder: recorder)

        await service.syncLinkedPlaylists(context: context, now: now)

        #expect(recorder.syncedIDs == ["playlist-1"])
    }

    @Test("failed playlists retry even when recent")
    func failedPlaylistsRetryEvenWhenRecent() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 5_000)
        let playlist = playlist(lastSyncedAt: now.addingTimeInterval(-60), lastSyncError: "Network failed")
        context.insert(playlist)
        let recorder = SyncRecorder()
        let service = makeService(recorder: recorder)

        await service.syncLinkedPlaylists(context: context, now: now)

        #expect(recorder.syncedIDs == ["playlist-1"])
    }

    @Test("forced sync bypasses freshness gate")
    func forcedSyncBypassesFreshnessGate() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 7_000)
        let playlist = playlist(lastSyncedAt: now.addingTimeInterval(-60), lastSyncError: nil)
        context.insert(playlist)
        let recorder = SyncRecorder()
        let service = makeService(recorder: recorder)

        await service.syncLinkedPlaylists(context: context, now: now, force: true)

        #expect(recorder.syncedIDs == ["playlist-1"])
    }

    @Test("identity merge runs once after a cycle that mutated records")
    func identityMergeRunsOnceAfterACycleThatMutatedRecords() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 9_000)
        context.insert(playlist(lastSyncedAt: nil, lastSyncError: nil))
        context.insert(playlist(
            musicPlaylistID: "playlist-2",
            lastSyncedAt: nil,
            lastSyncError: nil
        ))
        let recorder = SyncRecorder()
        let service = makeService(recorder: recorder, insertedCount: 1)

        await service.syncLinkedPlaylists(context: context, now: now)

        #expect(recorder.syncedIDs.count == 2)
        #expect(recorder.mergeCount == 1)
    }

    @Test("identity merge is skipped when no sync mutated records")
    func identityMergeIsSkippedWhenNoSyncMutatedRecords() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 11_000)
        context.insert(playlist(lastSyncedAt: nil, lastSyncError: nil))
        let recorder = SyncRecorder()
        let service = makeService(recorder: recorder, insertedCount: 0)

        await service.syncLinkedPlaylists(context: context, now: now)

        #expect(recorder.syncedIDs == ["playlist-1"])
        #expect(recorder.mergeCount == 0)
    }

    @Test("identity merge is skipped on an all-fresh cycle")
    func identityMergeIsSkippedOnAnAllFreshCycle() async throws {
        let container = try OverplayTestSupport.makeModelContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 13_000)
        context.insert(playlist(lastSyncedAt: now.addingTimeInterval(-60), lastSyncError: nil))
        let recorder = SyncRecorder()
        let service = makeService(recorder: recorder, insertedCount: 1)

        await service.syncLinkedPlaylists(context: context, now: now)

        #expect(recorder.syncedIDs.isEmpty)
        #expect(recorder.mergeCount == 0)
    }

    private final class SyncRecorder {
        var syncedIDs: [String] = []
        var mergeCount = 0
    }

    private func makeService(recorder: SyncRecorder, insertedCount: Int = 1) -> PeriodicPlaylistSyncService {
        PeriodicPlaylistSyncService { playlist, _ in
            recorder.syncedIDs.append(playlist.musicPlaylistID)
            return PlaylistSyncSummary(fetchedCount: 1, insertedCount: insertedCount)
        } mergeDuplicateTrackIdentities: { _ in
            recorder.mergeCount += 1
        }
    }

    private func playlist(
        musicPlaylistID: String = "playlist-1",
        lastSyncedAt: Date?,
        lastSyncError: String?
    ) -> PlaylistRecord {
        PlaylistRecord(
            musicPlaylistID: musicPlaylistID,
            name: "Main",
            role: .oneTruePlaylist,
            lastSyncedAt: lastSyncedAt,
            lastSyncError: lastSyncError
        )
    }
}
