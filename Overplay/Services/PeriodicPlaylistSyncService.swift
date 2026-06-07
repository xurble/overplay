import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PeriodicPlaylistSyncService {
    let initialDelay: Duration
    let interval: Duration

    @ObservationIgnored private var syncTask: Task<Void, Never>?

    init(
        initialDelay: Duration = .seconds(10),
        interval: Duration = .seconds(30 * 60)
    ) {
        self.initialDelay = initialDelay
        self.interval = interval
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
        playbackController: PlaybackController? = nil
    ) async {
        let playlists: [PlaylistRecord]

        do {
            playlists = try PlaylistRepository.activePlaylists(in: context)
        } catch {
            return
        }

        for playlist in playlists {
            do {
                _ = try await PlaylistSyncService().syncPlaylist(playlist, in: context)
                playbackController?.reconcileStoredOrder(for: playlist, context: context)
            } catch {
                playlist.lastSyncError = error.localizedDescription
                playlist.updatedAt = .now
                try? context.save()
            }
        }
    }
}
