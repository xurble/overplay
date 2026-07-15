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
    let interPlaylistDelay: Duration

    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private let syncPlaylist: @MainActor (PlaylistRecord, ModelContext) async throws -> PlaylistSyncSummary
    @ObservationIgnored private let mergeDuplicateTrackIdentities: @MainActor (ModelContext) async throws -> Void

    init(
        initialDelay: Duration = .seconds(10),
        interval: Duration = .seconds(30 * 60),
        automaticSyncFreshnessInterval: TimeInterval = 30 * 60,
        interPlaylistDelay: Duration = .milliseconds(500),
        syncPlaylist: @escaping @MainActor (PlaylistRecord, ModelContext) async throws -> PlaylistSyncSummary = { playlist, context in
            try await PlaylistSyncService().syncPlaylist(playlist, in: context, runIdentityMerge: false)
        },
        mergeDuplicateTrackIdentities: @escaping @MainActor (ModelContext) async throws -> Void = { context in
            try await TrackIdentityMergeService.mergeDuplicates(in: context)
        }
    ) {
        self.initialDelay = initialDelay
        self.interval = interval
        self.automaticSyncFreshnessInterval = automaticSyncFreshnessInterval
        self.interPlaylistDelay = interPlaylistDelay
        self.syncPlaylist = syncPlaylist
        self.mergeDuplicateTrackIdentities = mergeDuplicateTrackIdentities
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

        let orderedPlaylists = Self.prioritized(
            playlists,
            currentPlaylistID: playbackController?.currentPlaylistID,
            selectedPlaylistID: try? SettingsRepository.settings(in: context).selectedPlaylistID
        )

        var didMutateRecords = false
        var didSyncAnyPlaylist = false
        for playlist in orderedPlaylists {
            guard !Task.isCancelled else { return }
            guard shouldSync(playlist, now: now, force: force) else {
                logSkippedSync(for: playlist, now: now)
                continue
            }

            // Space playlists out so a catch-up cycle after long idle never
            // occupies the main actor back-to-back; stale playlists are
            // preferable to an unresponsive app.
            if didSyncAnyPlaylist, interPlaylistDelay > .zero {
                try? await Task.sleep(for: interPlaylistDelay)
                guard !Task.isCancelled else { return }
            }
            didSyncAnyPlaylist = true

            do {
                let summary = try await syncPlaylist(playlist, context)
                didMutateRecords = didMutateRecords || summary.didMutateRecords
                playbackController?.reconcileStoredOrder(for: playlist, context: context)
            } catch {
                playlist.lastSyncError = error.localizedDescription
                playlist.updatedAt = .now
                try? context.save()
            }
        }

        // The identity merge scans the whole library, so one gated pass per
        // cycle: only after a sync actually changed durable records.
        if didMutateRecords {
            try? await mergeDuplicateTrackIdentities(context)
        }
    }

    /// Catch-up ordering: the playlist the user is listening to first, then
    /// the selected default playlist, then the rest in stored order.
    nonisolated static func prioritized(
        _ playlists: [PlaylistRecord],
        currentPlaylistID: String?,
        selectedPlaylistID: String?
    ) -> [PlaylistRecord] {
        playlists.sorted { left, right in
            priorityRank(left, currentPlaylistID: currentPlaylistID, selectedPlaylistID: selectedPlaylistID)
                < priorityRank(right, currentPlaylistID: currentPlaylistID, selectedPlaylistID: selectedPlaylistID)
        }
    }

    private nonisolated static func priorityRank(
        _ playlist: PlaylistRecord,
        currentPlaylistID: String?,
        selectedPlaylistID: String?
    ) -> Int {
        if playlist.musicPlaylistID == currentPlaylistID {
            return 0
        }
        if playlist.musicPlaylistID == selectedPlaylistID {
            return 1
        }
        return 2
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
