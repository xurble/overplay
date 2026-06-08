import Foundation
import SwiftData

enum CarPlayLibrarySnapshot {
    static func playlistSummaries(in context: ModelContext) throws -> [PlaylistSummaryPresentation] {
        let playlists = try PlaylistRepository.activePlaylists(in: context)
        let items = try PlaylistItemRepository.allItems(in: context)
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
        evictAfterSkips: Int,
        in context: ModelContext
    ) throws -> [TrackSummaryPresentation] {
        let items = try PlaylistItemRepository.playableItems(forPlaylistID: playlistID, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        let builder = PlaylistPresentationBuilder(
            playlists: [],
            items: items,
            tracks: tracks,
            evictAfterSkips: evictAfterSkips
        )

        return builder.trackSummaries(forPlaylistID: playlistID)
    }
}
