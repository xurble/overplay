import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PlaylistSelectionViewModel {
    struct Dependencies {
        var fetchLibraryPlaylists: () async throws -> [AppleMusicPlaylist]
        var createManagedOneTruePlaylist: (_ name: String, _ sourcePlaylistID: String?, _ context: ModelContext) async throws -> PlaylistRecord
        var syncPlaylist: (_ playlist: PlaylistRecord, _ context: ModelContext) async throws -> Int
        var syncPlaylistID: (_ playlistID: String, _ context: ModelContext) async throws -> Int
        var syncAllLinkedPlaylists: (_ playlists: [PlaylistRecord], _ context: ModelContext) async throws -> Int
        var reconcileStoredOrder: (_ playlist: PlaylistRecord, _ context: ModelContext) -> Void
        var dismiss: () -> Void

        static func live(
            playbackController: PlaybackController,
            dismiss: @escaping () -> Void
        ) -> Dependencies {
            Dependencies {
                try await PlaylistSyncService().fetchLibraryPlaylists()
            } createManagedOneTruePlaylist: { name, sourcePlaylistID, context in
                if let sourcePlaylistID {
                    try await PlaylistSyncService().createManagedOneTruePlaylist(
                        named: name,
                        copyingTracksFrom: sourcePlaylistID,
                        in: context
                    )
                } else {
                    try await PlaylistSyncService().createManagedOneTruePlaylist(named: name, in: context)
                }
            } syncPlaylist: { playlist, context in
                try await PlaylistSyncService().syncPlaylist(playlist, in: context)
            } syncPlaylistID: { playlistID, context in
                try await PlaylistSyncService().syncPlaylist(id: playlistID, source: .appleMusic, in: context)
            } syncAllLinkedPlaylists: { playlists, context in
                let syncService = PlaylistSyncService()
                var syncedCount = 0
                for playlist in playlists {
                    syncedCount += try await syncService.syncPlaylist(playlist, in: context)
                }
                return syncedCount
            } reconcileStoredOrder: { playlist, context in
                playbackController.reconcileStoredOrder(for: playlist, context: context)
            } dismiss: {
                dismiss()
            }
        }
    }

    var playlists: [AppleMusicPlaylist] = []
    var searchText = ""
    var isLoading = false
    var isSyncingAll = false
    var isCreatingOneTruePlaylist = false
    var syncingPlaylistIDs = Set<UUID>()
    var newPlaylistName = "Overplay"
    var message: String?

    var filteredPlaylists: [AppleMusicPlaylist] {
        guard !searchText.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func loadPlaylists(dependencies: Dependencies) async {
        isLoading = true
        defer { isLoading = false }

        do {
            playlists = try await dependencies.fetchLibraryPlaylists()
            message = playlists.isEmpty ? "No Apple Music library playlists were found." : nil
        } catch {
            message = error.localizedDescription
        }
    }

    func select(
        _ playlist: AppleMusicPlaylist,
        oneTruePlaylist: PlaylistRecord?,
        context: ModelContext,
        dependencies: Dependencies
    ) {
        if oneTruePlaylist == nil {
            Task { await copyToManagedOneTruePlaylist(from: playlist, context: context, dependencies: dependencies) }
            return
        }

        do {
            try SettingsRepository.selectPlaylist(playlist, in: context)
            refreshPlaylistInBackground(id: playlist.id, context: context, dependencies: dependencies)
            dependencies.dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    func useIncomingOnly(_ playlist: AppleMusicPlaylist, context: ModelContext, dependencies: Dependencies) {
        do {
            try SettingsRepository.selectPlaylist(playlist, writePolicy: .incomingOnly, in: context)
            refreshPlaylistInBackground(id: playlist.id, context: context, dependencies: dependencies)
            dependencies.dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    func addTriage(_ playlist: AppleMusicPlaylist, context: ModelContext) {
        do {
            try PlaylistRepository.addTriagePlaylist(playlist, in: context)
            try context.save()
            message = "Added \(playlist.name) as a triage playlist."
        } catch {
            message = error.localizedDescription
        }
    }

    func makeOneTrue(_ playlist: PlaylistRecord, context: ModelContext, dependencies: Dependencies) {
        do {
            try SettingsRepository.selectPlaylist(
                AppleMusicPlaylist(id: playlist.musicPlaylistID, name: playlist.name, trackCount: nil),
                writePolicy: playlist.writePolicy,
                in: context
            )
            refreshPlaylistInBackground(playlist, context: context, dependencies: dependencies)
            dependencies.dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    func createManagedOneTruePlaylist(context: ModelContext, dependencies: Dependencies) async {
        isCreatingOneTruePlaylist = true
        defer { isCreatingOneTruePlaylist = false }

        do {
            let playlist = try await dependencies.createManagedOneTruePlaylist(newPlaylistName, nil, context)
            try SettingsRepository.selectPlaylist(
                AppleMusicPlaylist(id: playlist.musicPlaylistID, name: playlist.name, trackCount: 0),
                writePolicy: .managed,
                in: context
            )
            message = "Created \(playlist.name) in Apple Music."
            dependencies.dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    func copyToManagedOneTruePlaylist(
        from sourcePlaylist: AppleMusicPlaylist,
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        isCreatingOneTruePlaylist = true
        defer { isCreatingOneTruePlaylist = false }

        do {
            let playlist = try await dependencies.createManagedOneTruePlaylist(newPlaylistName, sourcePlaylist.id, context)
            try SettingsRepository.selectPlaylist(
                AppleMusicPlaylist(id: playlist.musicPlaylistID, name: playlist.name, trackCount: sourcePlaylist.trackCount),
                writePolicy: .managed,
                in: context
            )
            message = "Copied \(sourcePlaylist.name) to \(playlist.name)."
            dependencies.dismiss()
        } catch {
            message = error.localizedDescription
        }
    }

    func sync(_ playlist: PlaylistRecord, context: ModelContext, dependencies: Dependencies) async {
        syncingPlaylistIDs.insert(playlist.id)
        defer { syncingPlaylistIDs.remove(playlist.id) }

        do {
            let count = try await dependencies.syncPlaylist(playlist, context)
            dependencies.reconcileStoredOrder(playlist, context)
            message = "Synced \(count) tracks from \(playlist.name) (Apple Music)."
        } catch {
            message = error.localizedDescription
        }
    }

    func syncAllLinkedPlaylists(
        _ linkedPlaylists: [PlaylistRecord],
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        isSyncingAll = true
        defer { isSyncingAll = false }

        do {
            let count = try await dependencies.syncAllLinkedPlaylists(linkedPlaylists, context)
            for playlist in linkedPlaylists {
                dependencies.reconcileStoredOrder(playlist, context)
            }
            message = "Synced \(count) tracks across linked playlists."
        } catch {
            message = error.localizedDescription
        }
    }

    func refreshPlaylistInBackground(
        _ playlist: PlaylistRecord,
        context: ModelContext,
        dependencies: Dependencies
    ) {
        Task(priority: .background) {
            do {
                _ = try await dependencies.syncPlaylist(playlist, context)
                dependencies.reconcileStoredOrder(playlist, context)
            } catch {
                playlist.lastSyncError = error.localizedDescription
                playlist.updatedAt = .now
                try? context.save()
            }
        }
    }

    func refreshPlaylistInBackground(id playlistID: String, context: ModelContext, dependencies: Dependencies) {
        Task(priority: .background) {
            do {
                _ = try await dependencies.syncPlaylistID(playlistID, context)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
