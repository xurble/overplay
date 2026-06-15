import Foundation
import Observation
import OSLog
import SwiftData

@MainActor
@Observable
final class PeriodicPlaylistSyncService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "PeriodicPlaylistSync"
    )

    let initialDelay: Duration
    let interval: Duration
    let automaticSyncFreshnessInterval: TimeInterval

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private let syncPlaylist: @MainActor (PlaylistRecord, ModelContext) async throws -> Int

    init(
        initialDelay: Duration = .seconds(10),
        interval: Duration = .seconds(30 * 60),
        automaticSyncFreshnessInterval: TimeInterval = 30 * 60,
        syncPlaylist: @escaping @MainActor (PlaylistRecord, ModelContext) async throws -> Int = { playlist, context in
            try await PlaylistSyncService().syncPlaylist(playlist, in: context)
        }
    ) {
        self.initialDelay = initialDelay
        self.interval = interval
        self.automaticSyncFreshnessInterval = automaticSyncFreshnessInterval
        self.syncPlaylist = syncPlaylist
    }

    func start(
        context: ModelContext,
        playbackController: PlaybackController
    ) {
        guard syncTask == nil else { return }

        syncTask = Task(priority: .background) { @MainActor [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: initialDelay)

            while !Task.isCancelled {
                await syncLinkedPlaylists(
                    context: context,
                    playbackController: playbackController
                )
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
    }

    func syncLinkedPlaylists(
        context: ModelContext,
        playbackController: PlaybackController? = nil,
        now: Date = .now,
        force: Bool = false
    ) async {
        let playlists: [PlaylistRecord]

        do {
            playlists = try PlaylistRepository.activePlaylists(in: context)
        } catch {
            return
        }

        for playlist in playlists {
            guard shouldSync(playlist, now: now, force: force) else {
                logSkippedSync(for: playlist, now: now)
                continue
            }

            do {
                _ = try await syncPlaylist(playlist, context)
                playbackController?.reconcileStoredOrder(for: playlist, context: context)
            } catch {
                playlist.lastSyncError = error.localizedDescription
                playlist.updatedAt = .now
                try? context.save()
            }
        }
    }

    func shouldSync(_ playlist: PlaylistRecord, now: Date = .now, force: Bool = false) -> Bool {
        guard !force else { return true }
        guard playlist.lastSyncError == nil else { return true }
        guard let lastSyncedAt = playlist.lastSyncedAt else { return true }
        return now.timeIntervalSince(lastSyncedAt) >= automaticSyncFreshnessInterval
    }

    private func logSkippedSync(for playlist: PlaylistRecord, now: Date) {
        let age = playlist.lastSyncedAt.map { now.timeIntervalSince($0) } ?? 0
        Self.logger.info(
            """
            Skipped playlist sync for '\(playlist.name, privacy: .public)' \
            reason=recentlySynced \
            ageSeconds=\(age, privacy: .public) \
            freshnessSeconds=\(self.automaticSyncFreshnessInterval, privacy: .public) \
            fetched=0 inserted=0 updated=0 unchanged=0 skipped=1
            """
        )
    }
}
