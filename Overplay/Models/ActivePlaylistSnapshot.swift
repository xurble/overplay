import Foundation

struct ActivePlaylistSnapshot: Equatable, Sendable {
    struct Row: Equatable, Identifiable, Sendable {
        var id: UUID
        var playlistID: UUID
        var trackID: UUID
        var localTrackID: String
        var musicItemIDs: [String]
        var title: String
        var artistName: String
        var albumTitle: String?
        var artworkURLString: String?
        var skipCount: Int
        var playthroughCount: Int
        var isProtected: Bool
        var isEvicted: Bool
        var isCurrent: Bool

        var isPlayable: Bool {
            !isEvicted
        }
    }

    var playlistID: UUID
    var musicPlaylistID: String
    var playbackScope: PlaylistPlaybackScope
    var rows: [Row]
    var updatedAt: Date

    init(
        playlist: PlaylistRecord,
        items: [PlaylistItemRecord],
        tracks: [TrackRecord],
        playbackOrderState: PlaybackOrderState,
        playbackScope: PlaylistPlaybackScope = .active,
        currentPlaylistItemID: UUID? = nil,
        currentLocalTrackID: String? = nil,
        currentMusicItemID: String? = nil,
        updatedAt: Date = .now
    ) {
        let tracksByID = tracks.firstValueDictionary(keyedBy: \.id)
        let orderedItems = PlaylistDisplayOrder.orderedItems(
            items.filter { $0.playlistID == playlist.id },
            state: playbackOrderState,
            scope: playbackScope
        )

        self.playlistID = playlist.id
        self.musicPlaylistID = playlist.musicPlaylistID
        self.playbackScope = playbackScope
        self.rows = orderedItems.compactMap { item in
            guard let track = tracksByID[item.trackID] else { return nil }
            let localTrackID = item.trackID.uuidString
            let musicItemIDs = PlaybackQueueBuilder.musicItemIDs(for: track)
            return Row(
                id: item.id,
                playlistID: item.playlistID,
                trackID: item.trackID,
                localTrackID: localTrackID,
                musicItemIDs: musicItemIDs,
                title: track.title,
                artistName: track.artistName,
                albumTitle: track.albumTitle,
                artworkURLString: track.artworkURLTemplate,
                skipCount: item.skipCount,
                playthroughCount: item.playthroughCount,
                isProtected: item.protected,
                isEvicted: item.evictedAt != nil,
                isCurrent: Self.rowIsCurrent(
                    item: item,
                    track: track,
                    localTrackID: localTrackID,
                    currentPlaylistItemID: currentPlaylistItemID,
                    currentLocalTrackID: currentLocalTrackID,
                    currentMusicItemID: currentMusicItemID
                )
            )
        }
        self.updatedAt = updatedAt
    }

    /// Patches one item's counter/protection fields in place — an
    /// evaluation outcome only ever touches a single row, so callers can
    /// avoid refetching the whole playlist. Returns nil when the item has
    /// no row or its eviction state changed (membership/order now differ),
    /// signalling that a full rebuild is required instead.
    func updatingRow(for item: PlaylistItemRecord) -> ActivePlaylistSnapshot? {
        guard let index = rows.firstIndex(where: { $0.id == item.id }) else {
            return nil
        }

        var row = rows[index]
        guard row.isEvicted == (item.evictedAt != nil) else {
            return nil
        }

        row.skipCount = item.skipCount
        row.playthroughCount = item.playthroughCount
        row.isProtected = item.protected

        var snapshot = self
        snapshot.rows[index] = row
        snapshot.updatedAt = .now
        return snapshot
    }

    func updatingCurrentRow(
        currentPlaylistItemID: UUID?,
        currentLocalTrackID: String?,
        currentMusicItemID: String?
    ) -> ActivePlaylistSnapshot {
        let updatedRows = rows.map { row in
            var row = row
            row.isCurrent = row.id == currentPlaylistItemID
                || row.localTrackID == currentLocalTrackID
                || currentMusicItemID.map { row.musicItemIDs.contains($0) } == true
            return row
        }
        guard updatedRows != rows else { return self }

        var snapshot = self
        snapshot.rows = updatedRows
        snapshot.updatedAt = .now
        return snapshot
    }

    private static func rowIsCurrent(
        item: PlaylistItemRecord,
        track: TrackRecord,
        localTrackID: String,
        currentPlaylistItemID: UUID?,
        currentLocalTrackID: String?,
        currentMusicItemID: String?
    ) -> Bool {
        if item.id == currentPlaylistItemID {
            return true
        }

        if localTrackID == currentLocalTrackID {
            return true
        }

        guard let currentMusicItemID else {
            return false
        }

        return PlaybackQueueBuilder.musicItemIDs(for: track).contains(currentMusicItemID)
    }
}
