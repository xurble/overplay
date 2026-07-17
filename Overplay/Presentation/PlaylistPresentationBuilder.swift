import Foundation

struct PlaylistPresentationBuilder {
    private let playlists: [PlaylistRecord]
    private let items: [PlaylistItemRecord]
    private let tracksByID: [UUID: TrackRecord]
    private let currentPlaylistID: String?

    init(
        playlists: [PlaylistRecord],
        items: [PlaylistItemRecord],
        tracks: [TrackRecord],
        currentPlaylistID: String? = nil
    ) {
        self.playlists = playlists
        self.items = items
        self.tracksByID = tracks.firstValueDictionary(keyedBy: \.id)
        self.currentPlaylistID = currentPlaylistID
    }

    func activePlaylistSummaries() -> [PlaylistSummaryPresentation] {
        let summaries = playlists
            .filter(\.isActive)
            .map { summary($0) }
        return summaries.sorted { left, right in
            PlaylistSummaryPresentation.areInDisplayOrder(left, right)
        }
    }

    func summary(for playlist: PlaylistRecord) -> PlaylistSummaryPresentation {
        summary(playlist)
    }

    func dashboardSummary(forPlaylistID playlistID: UUID) -> DashboardSummary {
        DashboardSummary(items: itemsForPlaylist(playlistID))
    }

    func trackSummaries(
        forPlaylistID playlistID: UUID,
        playbackOrderState: PlaybackOrderState? = nil,
        scope: PlaylistPlaybackScope = .active
    ) -> [TrackSummaryPresentation] {
        let scopedItems = itemsForPlaylist(playlistID).filter { scope.includes($0) }
        let orderedItems = playbackOrderState.map {
            PlaylistDisplayOrder.orderedItems(scopedItems, state: $0, scope: scope)
        } ?? scopedItems.sorted(by: areItemsInPlaylistOrder)

        return orderedItems.compactMap { item in
            guard let track = tracksByID[item.trackID] else { return nil }

            return TrackSummaryPresentation(
                id: item.id,
                playlistID: item.playlistID,
                trackID: track.id,
                title: track.title,
                artistName: track.artistName,
                albumTitle: track.albumTitle,
                artworkURLString: track.artworkURLTemplate,
                skipCount: item.skipCount,
                playthroughCount: item.playthroughCount,
                isPlayable: scope == .retired || item.isPlayable,
                isRetired: item.evictedAt != nil
            )
        }
    }

    func representativeArtworkURL(for playlist: PlaylistRecord) -> String? {
        PlaylistArtworkSelector.representativeArtworkURL(
            for: playlist,
            items: items,
            tracksByID: tracksByID
        )
    }

    private func summary(_ playlist: PlaylistRecord) -> PlaylistSummaryPresentation {
        let playlistItems = itemsForPlaylist(playlist.id)
        return PlaylistSummaryPresentation(
            id: playlist.id,
            musicPlaylistID: playlist.musicPlaylistID,
            title: playlist.name,
            artworkURLString: representativeArtworkURL(for: playlist),
            role: playlist.role,
            source: playlist.source,
            writePolicy: playlist.writePolicy,
            activeTrackCount: playlistItems.count,
            playableTrackCount: playlistItems.filter(\.isPlayable).count,
            lastSyncedAt: playlist.lastSyncedAt,
            isCurrentPlaybackPlaylist: playlist.musicPlaylistID == currentPlaylistID
        )
    }

    private func itemsForPlaylist(_ playlistID: UUID) -> [PlaylistItemRecord] {
        items.filter { $0.playlistID == playlistID }
    }

    private func areItemsInPlaylistOrder(_ left: PlaylistItemRecord, _ right: PlaylistItemRecord) -> Bool {
        return left.createdAt < right.createdAt
    }
}
