import Foundation
import Observation
import SwiftData

/// The Triage Sources list: library playlists to link as sources, and the
/// linked ones to sync or unlink. The One True Playlist is not chosen here:
/// Overplay creates it (`SETUP-001`), the only way it can edit it later.
@MainActor
@Observable
final class PlaylistSelectionViewModel {
    struct Dependencies {
        var fetchLibraryPlaylists: () async throws -> [AppleMusicPlaylist]
        var syncPlaylist: (_ playlist: PlaylistRecord, _ context: ModelContext) async throws -> Int
        var reconcileStoredOrder: (_ playlist: PlaylistRecord, _ context: ModelContext) -> Void

        static func live(playbackController: PlaybackController) -> Dependencies {
            Dependencies {
                try await PlaylistSyncService().fetchLibraryPlaylists()
            } syncPlaylist: { playlist, context in
                try await PlaylistSyncService().syncPlaylist(playlist, in: context).fetchedCount
            } reconcileStoredOrder: { playlist, context in
                playbackController.reconcilePlaylistSelection(context: context)
                playbackController.reconcileStoredOrder(for: playlist, context: context)
            }
        }
    }

    var playlists: [AppleMusicPlaylist] = []
    var searchText = ""
    var isLoading = false
    var syncingPlaylistIDs = Set<UUID>()
    var message: String?

    var filteredPlaylists: [AppleMusicPlaylist] {
        guard !searchText.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func trackCount(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord]
    ) -> Int {
        if let remoteTrackCount = playlists.first(where: { $0.id == playlist.musicPlaylistID })?.trackCount {
            return remoteTrackCount
        }

        return playlistItems.count {
            $0.sourceMusicPlaylistIDs.contains(playlist.musicPlaylistID)
        }
    }

    func loadPlaylists(dependencies: Dependencies) async {
        isLoading = true
        defer { isLoading = false }

        do {
            playlists = try await dependencies.fetchLibraryPlaylists()
            message = playlists.isEmpty ? "No Apple Music library playlists were found." : nil
        } catch {
            message = UserFacingError.message(for: error)
        }
    }

    func addTriageSource(_ playlist: AppleMusicPlaylist, context: ModelContext) {
        do {
            try PlaylistRepository.addTriageSource(playlist, in: context)
            try context.save()
            message = "\(playlist.name) now feeds the triage bucket."
        } catch {
            message = UserFacingError.message(for: error)
        }
    }

    func removeTriageSource(
        _ playlist: PlaylistRecord, context: ModelContext,
        playbackController: PlaybackController? = nil
    ) {
        do {
            if let playbackController {
                try playbackController.removeTriageSource(playlist, context: context)
            } else {
                try PlaylistRepository.removeTriageSource(playlist, in: context)
            }
            message = "\(playlist.name) no longer feeds the triage bucket."
        } catch {
            message = UserFacingError.message(for: error)
        }
    }

    func sync(_ playlist: PlaylistRecord, context: ModelContext, dependencies: Dependencies) async {
        guard playlist.isActive, playlist.hasRemoteSource else {
            message = "\(playlist.name) is no longer linked."
            return
        }

        syncingPlaylistIDs.insert(playlist.id)
        defer { syncingPlaylistIDs.remove(playlist.id) }

        do {
            let count = try await dependencies.syncPlaylist(playlist, context)
            dependencies.reconcileStoredOrder(playlist, context)
            message = "Synced \(count) tracks from \(playlist.name) (Apple Music)."
        } catch {
            message = UserFacingError.message(for: error)
        }
    }
}
