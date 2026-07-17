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
        var isRetired: Bool
    }

    struct Dependencies {
        var playPlaylistFromTrack: (PlaylistRecord, TrackRecord, PlaylistPlaybackScope, OverplaySettings, ModelContext) async -> Void
        var playPlaylist: (PlaylistRecord, PlaylistPlaybackScope, OverplaySettings, ModelContext) async -> Void
        var syncPlaylist: (PlaylistRecord, ModelContext) async throws -> Int
        var reconcileStoredOrder: (PlaylistRecord, ModelContext) -> Void
        var promote: (PlaylistItemRecord, PlaylistRecord, ModelContext) async throws -> Void
        var evict: (PlaylistItemRecord, PlaylistRecord, ModelContext) throws -> Void
        var restore: (PlaylistItemRecord, PlaylistRecord, ModelContext) throws -> Void

        static func live(playbackController: PlaybackController) -> Self {
            Self(
                playPlaylistFromTrack: { playlist, track, scope, settings, context in
                    await playbackController.playPlaylist(playlist, startingAt: track, scope: scope, settings: settings, context: context)
                },
                playPlaylist: { playlist, scope, settings, context in
                    await playbackController.playPlaylist(playlist, scope: scope, settings: settings, context: context)
                },
                syncPlaylist: { playlist, context in
                    try await PlaylistSyncService().syncPlaylist(playlist, in: context).fetchedCount
                },
                reconcileStoredOrder: { playlist, context in
                    playbackController.reconcileStoredOrder(for: playlist, context: context)
                },
                promote: { item, playlist, context in
                    _ = try await playbackController.promoteTrack(item, playlist: playlist, context: context)
                },
                evict: { item, playlist, context in
                    try playbackController.retireTrack(
                        item,
                        playlist: playlist,
                        message: "Retired manually",
                        context: context
                    )
                },
                restore: { item, playlist, context in
                    try playbackController.restoreTrack(item, playlist: playlist, context: context)
                }
            )
        }
    }

    var isSyncing = false
    var promotingItemIDs = Set<UUID>()
    var evictingItemIDs = Set<UUID>()
    var restoringItemIDs = Set<UUID>()
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
        scope: PlaylistPlaybackScope = .active
    ) -> DetailPresentation {
        _ = playbackItemMetadataVersion
        if let activePlaylistSnapshot,
           activePlaylistSnapshot.musicPlaylistID == playlist.musicPlaylistID,
           activePlaylistSnapshot.playbackScope == scope,
           currentPlaylistID == playlist.musicPlaylistID {
            return activeDetailPresentation(
                for: playlist,
                snapshot: activePlaylistSnapshot,
                scope: scope
            )
        }

        let visibleItems = visibleItems(for: playlist, playlistItems: playlistItems, scope: scope)
        let orderedItems = PlaylistDisplayOrder.orderedItems(visibleItems, state: playbackOrderState, scope: scope)
        let tracksByID = tracks.firstValueDictionary(keyedBy: \.id)
        let rows = orderedItems.compactMap { item -> TrackRowPresentation? in
            guard let track = tracksByID[item.trackID] else { return nil }
            let isPlayableInScope = scope == .retired || item.isPlayable

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
                    playthroughCount: item.playthroughCount,
                    isPlayable: isPlayableInScope,
                    isRetired: item.evictedAt != nil
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
                isPlayable: isPlayableInScope,
                isRetired: item.evictedAt != nil
            )
        }
        let builder = PlaylistPresentationBuilder(
            playlists: [playlist],
            items: playlistItems.filter { $0.playlistID == playlist.id },
            tracks: tracks,
            currentPlaylistID: currentTrack == nil && currentLocalTrackID == nil ? nil : currentPlaylistID
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
        scope: PlaylistPlaybackScope
    ) -> DetailPresentation {
        let visibleRows = snapshot.rows.filter { row in
            scope == .active ? !row.isEvicted : row.isEvicted
        }
        let rows = visibleRows.map { row in
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
                    playthroughCount: row.playthroughCount,
                    isPlayable: scope == .retired || row.isPlayable,
                    isRetired: row.isEvicted
                ),
                isCurrent: row.isCurrent,
                isPlayable: scope == .retired || row.isPlayable,
                isRetired: row.isEvicted
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
            summary: DashboardSummary(activeRows: snapshot.rows),
            rows: rows
        )
    }

    func orderedItems(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord],
        playbackOrderState: PlaybackOrderState
    ) -> [PlaylistItemRecord] {
        PlaylistDisplayOrder.orderedItems(
            visibleItems(for: playlist, playlistItems: playlistItems, scope: .active),
            state: playbackOrderState,
            scope: .active
        )
    }

    func track(for item: PlaylistItemRecord, tracks: [TrackRecord]) -> TrackRecord? {
        tracks.firstValueDictionary(keyedBy: \.id)[item.trackID]
    }

    func summary(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord],
        tracks: [TrackRecord],
        currentPlaylistID: String?
    ) -> DashboardSummary {
        presentationBuilder(
            for: playlist,
            playlistItems: playlistItems,
            tracks: tracks,
            currentPlaylistID: currentPlaylistID
        )
        .dashboardSummary(forPlaylistID: playlist.id)
    }

    func playlistPresentation(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord],
        tracks: [TrackRecord],
        currentPlaylistID: String?
    ) -> PlaylistSummaryPresentation {
        presentationBuilder(
            for: playlist,
            playlistItems: playlistItems,
            tracks: tracks,
            currentPlaylistID: currentPlaylistID
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
        scope: PlaylistPlaybackScope = .active,
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        guard scope == .retired || item.isPlayable else { return }
        await dependencies.playPlaylistFromTrack(playlist, track, scope, settings, context)
    }

    func playPlaylist(
        playlist: PlaylistRecord,
        settings: OverplaySettings,
        scope: PlaylistPlaybackScope = .active,
        isCurrentPlaylist: Bool,
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        guard !isCurrentPlaylist else { return }
        await dependencies.playPlaylist(playlist, scope, settings, context)
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
            try await dependencies.promote(item, playlist, context)
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
            message = "Retired \(track.title)."
        } catch {
            message = error.localizedDescription
        }
    }

    func restore(
        _ item: PlaylistItemRecord,
        track: TrackRecord,
        playlist: PlaylistRecord,
        context: ModelContext,
        dependencies: Dependencies
    ) async {
        guard item.evictedAt != nil else { return }
        restoringItemIDs.insert(item.id)
        defer { restoringItemIDs.remove(item.id) }

        do {
            try dependencies.restore(item, playlist, context)
            dependencies.reconcileStoredOrder(playlist, context)
            message = "Restored \(track.title)."
        } catch {
            message = error.localizedDescription
        }
    }

    private func visibleItems(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord],
        scope: PlaylistPlaybackScope
    ) -> [PlaylistItemRecord] {
        playlistItems.filter { $0.playlistID == playlist.id && scope.includes($0) }
    }

    private func presentationBuilder(
        for playlist: PlaylistRecord,
        playlistItems: [PlaylistItemRecord],
        tracks: [TrackRecord],
        currentPlaylistID: String?
    ) -> PlaylistPresentationBuilder {
        PlaylistPresentationBuilder(
            playlists: [playlist],
            items: playlistItems,
            tracks: tracks,
            currentPlaylistID: currentPlaylistID
        )
    }
}
