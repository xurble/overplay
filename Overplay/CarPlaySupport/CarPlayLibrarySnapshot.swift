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
        playbackOrderState: PlaybackOrderState? = nil,
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
        ).trackSummaries(forPlaylistID: playlistID, playbackOrderState: playbackOrderState, scope: scope)
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
