import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SearchMusicViewModel {
    struct Dependencies {
        var addSong: (_ songID: String, _ playlistID: String) async throws -> String
        var recordSuccessfulManualAdd: (_ result: SearchSongResult, _ playlist: PlaylistRecord, _ context: ModelContext) throws -> Void
        var recordFailedManualAdd: (_ result: SearchSongResult, _ playlist: PlaylistRecord, _ message: String, _ context: ModelContext) -> Void
        var syncPlaylist: (_ playlist: PlaylistRecord, _ context: ModelContext) async throws -> Void
        var reconcileStoredOrder: (_ playlist: PlaylistRecord, _ context: ModelContext) -> Void

        static func live(
            searchService: SearchService,
            playbackController: PlaybackController
        ) -> Dependencies {
            Dependencies { songID, playlistID in
                try await searchService.addSong(id: songID, toPlaylistID: playlistID)
            } recordSuccessfulManualAdd: { result, playlist, context in
                try PlaylistMutationService().recordSuccessfulManualAdd(result, to: playlist, in: context)
            } recordFailedManualAdd: { result, playlist, message, context in
                PlaylistMutationService().recordFailedManualAdd(result, to: playlist, message: message, in: context)
            } syncPlaylist: { playlist, context in
                _ = try await PlaylistSyncService().syncPlaylist(playlist, in: context)
            } reconcileStoredOrder: { playlist, context in
                playbackController.reconcileStoredOrder(for: playlist, context: context)
            }
        }
    }

    var searchText = ""
    var searchService = SearchService()
    var selectedPlaylistRecordID: UUID?
    var addingSongIDs = Set<String>()

    func activePlaylists(from playlists: [PlaylistRecord]) -> [PlaylistRecord] {
        playlists
            .filter { $0.isActive && $0.allowsRemoteWrites }
            .sorted { left, right in
                if left.role != right.role {
                    return left.role == .oneTruePlaylist
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    func selectedPlaylist(from playlists: [PlaylistRecord]) -> PlaylistRecord? {
        guard let selectedPlaylistRecordID else { return nil }
        return activePlaylists(from: playlists).first { $0.id == selectedPlaylistRecordID }
    }

    func selectDefaultPlaylistIfNeeded(
        playlists: [PlaylistRecord],
        settings: OverplaySettings,
        initialPlaylistID: String?
    ) {
        let activePlaylists = activePlaylists(from: playlists)
        if let selectedPlaylistRecordID,
           activePlaylists.contains(where: { $0.id == selectedPlaylistRecordID }) {
            return
        }

        selectedPlaylistRecordID = defaultPlaylist(
            activePlaylists: activePlaylists,
            settings: settings,
            initialPlaylistID: initialPlaylistID
        )?.id
    }

    func add(
        _ result: SearchSongResult,
        playlists: [PlaylistRecord],
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        guard let playlist = selectedPlaylist(from: playlists) else {
            searchService.message = "Choose a writable playlist before adding songs."
            return
        }

        guard playlist.allowsRemoteWrites else {
            searchService.message = "\(playlist.name) is incoming only, so Overplay will not write changes back to Apple Music."
            return
        }

        guard !addingSongIDs.contains(result.id) else {
            return
        }

        addingSongIDs.insert(result.id)
        defer { addingSongIDs.remove(result.id) }

        do {
            _ = try await dependencies.addSong(result.id, playlist.musicPlaylistID)
            try dependencies.recordSuccessfulManualAdd(result, playlist, context)
            if let syncMessage = await syncPlaylistIfPossible(playlist, context: context, dependencies: dependencies) {
                searchService.message = syncMessage
            } else {
                searchService.message = "Added \(result.title) to \(playlist.name)."
            }
        } catch {
            dependencies.recordFailedManualAdd(result, playlist, error.localizedDescription, context)
            searchService.message = "Could not add \(result.title) to \(playlist.name): \(error.localizedDescription)"
        }
    }

    func clearSearchIfNeeded(_ newValue: String) async {
        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await searchService.search("")
        }
    }

    func destinationTitle(for playlist: PlaylistRecord) -> String {
        switch playlist.role {
        case .oneTruePlaylist:
            "\(playlist.name) - Main"
        case .triage:
            "\(playlist.name) - Triage"
        }
    }

    func destinationImage(for playlist: PlaylistRecord) -> String {
        switch playlist.role {
        case .oneTruePlaylist:
            "star.fill"
        case .triage:
            "tray.fill"
        }
    }

    private func defaultPlaylist(
        activePlaylists: [PlaylistRecord],
        settings: OverplaySettings,
        initialPlaylistID: String?
    ) -> PlaylistRecord? {
        if let initialPlaylistID,
           let playlist = activePlaylists.first(where: { $0.musicPlaylistID == initialPlaylistID }) {
            return playlist
        }

        if let settingsPlaylistID = settings.selectedPlaylistID,
           let playlist = activePlaylists.first(where: { $0.musicPlaylistID == settingsPlaylistID }) {
            return playlist
        }

        return activePlaylists.first { $0.role == .oneTruePlaylist } ?? activePlaylists.first
    }

    private func syncPlaylistIfPossible(
        _ playlist: PlaylistRecord,
        context: ModelContext,
        dependencies: Dependencies
    ) async -> String? {
        do {
            try await dependencies.syncPlaylist(playlist, context)
            dependencies.reconcileStoredOrder(playlist, context)
            return nil
        } catch {
            return "Added to \(playlist.name), but sync failed: \(error.localizedDescription)"
        }
    }
}
