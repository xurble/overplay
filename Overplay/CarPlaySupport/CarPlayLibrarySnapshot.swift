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
            tracks: tracks,
            evictAfterSkips: 0
        )

        return builder.activePlaylistSummaries()
    }

    static func trackSummaries(
        forPlaylistID playlistID: UUID,
        playbackOrderState: PlaybackOrderState? = nil,
        in context: ModelContext
    ) throws -> [TrackSummaryPresentation] {
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistID, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        return PlaylistPresentationBuilder(
            playlists: [],
            items: items,
            tracks: tracks,
            evictAfterSkips: 0
        ).trackSummaries(forPlaylistID: playlistID, playbackOrderState: playbackOrderState)
    }
}
