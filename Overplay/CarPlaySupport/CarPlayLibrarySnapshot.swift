import Foundation
import SwiftData

enum CarPlayLibrarySnapshot {
    static func playlistSummaries(in context: ModelContext) throws -> [PlaylistSummaryPresentation] {
        let playlists = try PlaylistRepository.activePlaylists(in: context)
        let items = try PlaylistItemRepository.items(forPlaylistIDs: playlists.map(\.id), in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        let builder = PlaylistPresentationBuilder(
            playlists: playlists,
            items: items,
            tracks: tracks
        )

        var summaries = builder.activePlaylistSummaries()
        if let bucket = playlists.first(where: \.isTriageBucket) {
            summaries.append(builder.summary(for: bucket, scope: .retired))
        }
        return summaries
    }

    static func trackSummaries(
        forPlaylistID playlistID: UUID,
        scope: PlaylistPlaybackScope = .active,
        in context: ModelContext
    ) throws -> [TrackSummaryPresentation] {
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        let playlists = try PlaylistRepository.allPlaylists(in: context)
        return PlaylistPresentationBuilder(
            playlists: playlists,
            items: items,
            tracks: tracks
        ).trackSummaries(forPlaylistID: playlistID, scope: scope)
    }

    /// The rows `CurrentPlaylistItemMatcher` calls current, reading their
    /// tracks once for the whole list, and not at all when nothing here can
    /// be current. A row whose track cannot be read is not current.
    static func currentRowIDs(
        among rows: some Collection<TrackSummaryPresentation>,
        in playlist: PlaylistRecord,
        currentPlaylistID: String?,
        currentPlaylistItem: PlaylistItemRecord?,
        currentTrack: CurrentPlaybackTrack?,
        loadTracks: ([UUID]) -> [TrackRecord]
    ) -> Set<UUID> {
        guard playlist.musicPlaylistID == currentPlaylistID, currentPlaylistItem != nil || currentTrack != nil else { return [] }
        let tracksByID = loadTracks(rows.compactMap(\.trackID)).firstValueDictionary(keyedBy: \.id)
        return Set(rows.filter { row in
            guard let trackID = row.trackID, let track = tracksByID[trackID] else { return false }
            return CurrentPlaylistItemMatcher.isCurrent(
                itemID: row.id, track: track, playlist: playlist, currentPlaylistID: currentPlaylistID,
                currentPlaylistItem: currentPlaylistItem, currentTrack: currentTrack
            )
        }.map(\.id))
    }

    /// Active playback surfaces consume the controller-owned snapshot so a
    /// write performed in another SwiftData context is visible immediately.
    static func trackSummaries(
        from snapshot: ActivePlaylistSnapshot,
        playlistItems: [PlaylistItemRecord] = [],
        sourcePlaylists: [PlaylistRecord] = []
    ) -> [TrackSummaryPresentation] {
        let persistedItemsByID = playlistItems.firstValueDictionary(keyedBy: \.id)
        let playlistRole = sourcePlaylists.first { $0.id == snapshot.playlistID }?.role
        return snapshot.rows
            .filter { row in
                snapshot.playbackScope == .active ? !row.isEvicted : row.isEvicted
            }
            .map { row in
                TrackSummaryPresentation(
                    id: row.id,
                    playlistID: row.playlistID,
                    trackID: row.trackID,
                    title: row.title,
                    artistName: row.artistName,
                    albumTitle: row.albumTitle,
                    artworkURLString: row.artworkURLString,
                    skipCount: row.skipCount,
                    playthroughCount: row.playthroughCount,
                    applePlayCount: row.applePlayCount,
                    provenanceText: TrackSummaryPresentation.provenanceText(
                        sourceMusicPlaylistIDs: persistedItemsByID[row.id]?.sourceMusicPlaylistIDs
                            ?? row.sourceMusicPlaylistIDs,
                        playlistRole: playlistRole,
                        sourcePlaylists: sourcePlaylists
                    ),
                    isPlayable: snapshot.playbackScope == .retired || row.isPlayable,
                    isRetired: row.isEvicted
                )
            }
    }
}

/// The root list's playlist summaries, rebuilt only when something the root
/// shows has changed. Saves land at every track change with play counts and
/// the like, which the root does not show, so whether to rebuild is read from
/// the library each time rather than from which records a save touched.
struct CarPlayRootSummaries {
    /// Everything the root shows from a summary, and its order.
    private struct Shown: Equatable {
        var id: UUID
        var musicPlaylistID: String
        var name: String
        var role: PlaylistRole
        var activeCount: Int
    }

    private var shown: [Shown]?
    private var summaries: [PlaylistSummaryPresentation] = []

    mutating func current(
        in context: ModelContext,
        load: (ModelContext) throws -> [PlaylistSummaryPresentation] = { try CarPlayLibrarySnapshot.playlistSummaries(in: $0) }
    ) throws -> [PlaylistSummaryPresentation] {
        let latest = try Self.shown(in: context)
        if latest == shown { return summaries }
        summaries = try load(context)
        shown = latest
        return summaries
    }

    private static func shown(in context: ModelContext) throws -> [Shown] {
        try PlaylistRepository.activePlaylists(in: context).map { playlist in
            let id = playlist.id
            // Sources have no row of their own, and Retired's row shows no count.
            let active = FetchDescriptor<PlaylistItemRecord>(predicate: #Predicate { $0.playlistID == id && $0.evictedAt == nil })
            return Shown(id: id, musicPlaylistID: playlist.musicPlaylistID, name: playlist.name, role: playlist.role,
                         activeCount: playlist.role.isPlaybackContext ? try context.fetchCount(active) : 0)
        }
    }
}
