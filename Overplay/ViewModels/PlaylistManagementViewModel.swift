import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PlaylistManagementViewModel {
    struct DetailPresentation {
        var playlist: PlaylistSummaryPresentation
        var summary: DashboardSummary
        var rows: [TrackRowPresentation]
    }

    struct TrackRowPresentation: Identifiable {
        var id: UUID
        var item: PlaylistItemRecord?
        var track: TrackRecord?
        var trackID: UUID?
        var localTrackID: String
        var summary: TrackSummaryPresentation
        var isCurrent: Bool
        var isPlayable: Bool
    }

    struct Dependencies {
        var playPlaylistFromTrack: (PlaylistRecord, TrackRecord, OverplaySettings, ModelContext) async -> Void
        var playPlaylist: (PlaylistRecord, OverplaySettings, ModelContext) async -> Void
        var syncPlaylist: (PlaylistRecord, ModelContext) async throws -> Int
        var reconcileStoredOrder: (PlaylistRecord, ModelContext) -> Void
        var promote: (PlaylistItemRecord, ModelContext) async throws -> Void
        var evict: (PlaylistItemRecord, PlaylistRecord, ModelContext) throws -> Void

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
                },
                evict: { item, playlist, context in
                    try TrackHealthActionService.evictTrack(
                        item,
                        playlist: playlist,
                        message: "Evicted manually",
                        in: context
                    )
                }
            )
        }
    }

    var isSyncing = false
    var promotingItemIDs = Set<UUID>()
    var evictingItemIDs = Set<UUID>()
    var message: String?

    func detailPresentation(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord],
        tracks: [TrackRecord],
        playbackOrderState: PlaybackOrderState,
        currentPlaylistID: String?,
        currentPlaylistItem: PlaylistItemRecord?,
        currentLocalTrackID: String? = nil,
        currentTrack: CurrentPlaybackTrack?,
        playbackItemMetadataVersion: Int = 0,
        activePlaylistSnapshot: ActivePlaylistSnapshot? = nil,
        evictAfterSkips: Int
    ) -> DetailPresentation {
        _ = playbackItemMetadataVersion
        if let activePlaylistSnapshot,
           activePlaylistSnapshot.musicPlaylistID == playlist.musicPlaylistID,
           currentPlaylistID == playlist.musicPlaylistID {
            return activeDetailPresentation(
                for: playlist,
                snapshot: activePlaylistSnapshot,
                evictAfterSkips: evictAfterSkips
            )
        }

        let visibleItems = visibleItems(for: playlist, playlistItems: playlistItems)
        let orderedItems = PlaylistDisplayOrder.orderedItems(visibleItems, state: playbackOrderState)
        let tracksByID = tracks.firstValueDictionary(keyedBy: \.id)
        let rows = orderedItems.compactMap { item -> TrackRowPresentation? in
            guard let track = tracksByID[item.trackID] else { return nil }

            return TrackRowPresentation(
                id: item.id,
                item: item,
                track: track,
                trackID: track.id,
                localTrackID: item.trackID.uuidString,
                summary: TrackSummaryPresentation(
                    id: item.id,
                    playlistID: item.playlistID,
                    trackID: track.id,
                    title: track.title,
                    artistName: track.artistName,
                    albumTitle: track.albumTitle,
                    artworkURLString: track.artworkURLTemplate,
                    skipCount: item.skipCount,
                    isPlayable: item.isPlayable
                ),
                isCurrent: isCurrentItem(
                    item,
                    track: track,
                    playlist: playlist,
                    currentPlaylistID: currentPlaylistID,
                    currentPlaylistItem: currentPlaylistItem,
                    currentLocalTrackID: currentLocalTrackID,
                    currentTrack: currentTrack
                ),
                isPlayable: item.isPlayable
            )
        }
        let builder = PlaylistPresentationBuilder(
            playlists: [playlist],
            items: visibleItems,
            tracks: tracks,
            currentPlaylistID: currentTrack == nil && currentLocalTrackID == nil ? nil : currentPlaylistID,
            evictAfterSkips: evictAfterSkips
        )

        return DetailPresentation(
            playlist: builder.summary(for: playlist),
            summary: builder.dashboardSummary(forPlaylistID: playlist.id),
            rows: rows
        )
    }

    private func activeDetailPresentation(
        for playlist: PlaylistRecord,
        snapshot: ActivePlaylistSnapshot,
        evictAfterSkips: Int
    ) -> DetailPresentation {
        let rows = snapshot.rows.map { row in
            TrackRowPresentation(
                id: row.id,
                item: nil,
                track: nil,
                trackID: row.trackID,
                localTrackID: row.localTrackID,
                summary: TrackSummaryPresentation(
                    id: row.id,
                    playlistID: row.playlistID,
                    trackID: row.trackID,
                    title: row.title,
                    artistName: row.artistName,
                    albumTitle: row.albumTitle,
                    artworkURLString: row.artworkURLString,
                    skipCount: row.skipCount,
                    isPlayable: row.isPlayable
                ),
                isCurrent: row.isCurrent,
                isPlayable: row.isPlayable
            )
        }
        let playlistPresentation = PlaylistSummaryPresentation(
            id: playlist.id,
            musicPlaylistID: playlist.musicPlaylistID,
            title: playlist.name,
            artworkURLString: rows.first?.summary.artworkURLString,
            role: playlist.role,
            source: playlist.source,
            writePolicy: playlist.writePolicy,
            activeTrackCount: rows.count,
            playableTrackCount: rows.filter(\.isPlayable).count,
            lastSyncedAt: playlist.lastSyncedAt,
            isCurrentPlaybackPlaylist: true
        )

        return DetailPresentation(
            playlist: playlistPresentation,
            summary: DashboardSummary(activeRows: snapshot.rows, evictAfterSkips: evictAfterSkips),
            rows: rows
        )
    }

    func orderedItems(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord],
        playbackOrderState: PlaybackOrderState
    ) -> [PlaylistItemRecord] {
        PlaylistDisplayOrder.orderedItems(
            visibleItems(for: playlist, playlistItems: playlistItems),
            state: playbackOrderState
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
        currentLocalTrackID: String? = nil,
        currentTrack: CurrentPlaybackTrack?
    ) -> Bool {
        CurrentPlaylistItemMatcher.isCurrent(
            itemID: item.id,
            track: track,
            playlist: playlist,
            currentPlaylistID: currentPlaylistID,
            currentPlaylistItem: currentPlaylistItem,
            currentLocalTrackID: currentLocalTrackID,
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
            dependencies.reconcileStoredOrder(playlist, context)
            message = "Promoted \(track.title)."
        } catch {
            message = error.localizedDescription
        }
    }

    func evict(
        _ item: PlaylistItemRecord,
        track: TrackRecord,
        playlist: PlaylistRecord,
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        guard item.isPlayable else { return }
        evictingItemIDs.insert(item.id)
        defer { evictingItemIDs.remove(item.id) }

        do {
            try dependencies.evict(item, playlist, context)
            dependencies.reconcileStoredOrder(playlist, context)
            message = "Evicted \(track.title)."
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
