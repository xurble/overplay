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

        return builder.activePlaylistSummaries()
    }

    static func trackSummaries(
        forPlaylistID playlistID: UUID,
        playbackOrderState: PlaybackOrderState? = nil,
        scope: PlaylistPlaybackScope = .active,
        in context: ModelContext
    ) throws -> [TrackSummaryPresentation] {
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        return PlaylistPresentationBuilder(
            playlists: [],
            items: items,
            tracks: tracks
        ).trackSummaries(forPlaylistID: playlistID, playbackOrderState: playbackOrderState, scope: scope)
    }

    /// Active playback surfaces consume the controller-owned snapshot so a
    /// write performed in another SwiftData context is visible immediately.
    static func trackSummaries(from snapshot: ActivePlaylistSnapshot) -> [TrackSummaryPresentation] {
        snapshot.rows
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
                    isPlayable: snapshot.playbackScope == .retired || row.isPlayable,
                    isRetired: row.isEvicted
                )
            }
    }
}
