import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PlaylistManagementViewModel {
    struct Dependencies {
        var playPlaylistFromTrack: (PlaylistRecord, TrackRecord, OverplaySettings, ModelContext) async -> Void
        var playPlaylist: (PlaylistRecord, OverplaySettings, ModelContext) async -> Void
        var syncPlaylist: (PlaylistRecord, ModelContext) async throws -> Int
        var reconcileStoredOrder: (PlaylistRecord, ModelContext) -> Void
        var promote: (PlaylistItemRecord, ModelContext) async throws -> Void

        static func live(playbackController: PlaybackController) -> Self {
            Self(
                playPlaylistFromTrack: { playlist, track, settings, context in
                    await playbackController.playPlaylist(playlist, startingAt: track, settings: settings, context: context)
                },
                playPlaylist: { playlist, settings, context in
                    await playbackController.playPlaylist(playlist, settings: settings, context: context)
                },
                syncPlaylist: { playlist, context in
                    try await PlaylistSyncService().syncPlaylist(playlist, in: context)
                },
                reconcileStoredOrder: { playlist, context in
                    playbackController.reconcileStoredOrder(for: playlist, context: context)
                },
                promote: { item, context in
                    _ = try await PlaylistMutationService().promote(item: item, in: context)
                }
            )
        }
    }

    var isSyncing = false
    var promotingItemIDs = Set<UUID>()
    var message: String?

    func orderedItems(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord],
        playbackModeState: PlaybackModeState
    ) -> [PlaylistItemRecord] {
        PlaylistDisplayOrder.orderedItems(
            visibleItems(for: playlist, playlistItems: playlistItems),
            state: playbackModeState
        )
    }

    func track(for item: PlaylistItemRecord, tracks: [TrackRecord]) -> TrackRecord? {
        tracks.firstValueDictionary(keyedBy: \.id)[item.trackID]
    }

    func summary(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord],
        tracks: [TrackRecord],
        currentPlaylistID: String?,
        evictAfterSkips: Int
    ) -> DashboardSummary {
        presentationBuilder(
            for: playlist,
            playlistItems: playlistItems,
            tracks: tracks,
            currentPlaylistID: currentPlaylistID,
            evictAfterSkips: evictAfterSkips
        )
        .dashboardSummary(forPlaylistID: playlist.id)
    }

    func playlistPresentation(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord],
        tracks: [TrackRecord],
        currentPlaylistID: String?,
        evictAfterSkips: Int
    ) -> PlaylistSummaryPresentation {
        presentationBuilder(
            for: playlist,
            playlistItems: playlistItems,
            tracks: tracks,
            currentPlaylistID: currentPlaylistID,
            evictAfterSkips: evictAfterSkips
        )
        .summary(for: playlist)
    }

    func playButtonTitle(isCurrentPlaylist: Bool) -> String {
        isCurrentPlaylist ? "Playing" : "Play"
    }

    func isCurrentItem(
        _ item: PlaylistItemRecord,
        track: TrackRecord,
        playlist: PlaylistRecord,
        currentPlaylistID: String?,
        currentPlaylistItem: PlaylistItemRecord?,
        currentTrack: CurrentPlaybackTrack?
    ) -> Bool {
        CurrentPlaylistItemMatcher.isCurrent(
            itemID: item.id,
            track: track,
            playlist: playlist,
            currentPlaylistID: currentPlaylistID,
            currentPlaylistItem: currentPlaylistItem,
            currentTrack: currentTrack
        )
    }

    func play(
        _ item: PlaylistItemRecord,
        track: TrackRecord,
        playlist: PlaylistRecord,
        settings: OverplaySettings,
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        guard item.isPlayable else { return }
        await dependencies.playPlaylistFromTrack(playlist, track, settings, context)
    }

    func playPlaylist(
        playlist: PlaylistRecord,
        settings: OverplaySettings,
        isCurrentPlaylist: Bool,
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        guard !isCurrentPlaylist else { return }
        await dependencies.playPlaylist(playlist, settings, context)
    }

    func syncPlaylist(
        _ playlist: PlaylistRecord,
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let count = try await dependencies.syncPlaylist(playlist, context)
            dependencies.reconcileStoredOrder(playlist, context)
            message = "Synced \(count) tracks from \(playlist.name)."
        } catch {
            message = error.localizedDescription
        }
    }

    func promote(
        _ item: PlaylistItemRecord,
        track: TrackRecord,
        playlist: PlaylistRecord,
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        guard playlist.role == .triage else { return }
        promotingItemIDs.insert(item.id)
        defer { promotingItemIDs.remove(item.id) }

        do {
            try await dependencies.promote(item, context)
            message = "Promoted \(track.title)."
        } catch {
            message = error.localizedDescription
        }
    }

    private func visibleItems(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord]
    ) -> [PlaylistItemRecord] {
        playlistItems.filter { $0.playlistID == playlist.id }
    }

    private func presentationBuilder(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord],
        tracks: [TrackRecord],
        currentPlaylistID: String?,
        evictAfterSkips: Int
    ) -> PlaylistPresentationBuilder {
        PlaylistPresentationBuilder(
            playlists: [playlist],
            items: playlistItems,
            tracks: tracks,
            currentPlaylistID: currentPlaylistID,
            evictAfterSkips: evictAfterSkips
        )
    }
}
