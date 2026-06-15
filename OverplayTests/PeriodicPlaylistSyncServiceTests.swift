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

    private final class SyncRecorder {
        var syncedIDs: [String] = []
    }

    private func makeService(recorder: SyncRecorder) -> PeriodicPlaylistSyncService {
        PeriodicPlaylistSyncService { playlist, _ in
            recorder.syncedIDs.append(playlist.musicPlaylistID)
            return 1
        }
    }

    private func playlist(lastSyncedAt: Date?, lastSyncError: String?) -> PlaylistRecord {
        PlaylistRecord(
            musicPlaylistID: "playlist-1",
            name: "Main",
            role: .oneTruePlaylist,
            lastSyncedAt: lastSyncedAt,
            lastSyncError: lastSyncError
        )
    }
}
