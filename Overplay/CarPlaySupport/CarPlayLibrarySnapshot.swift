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
        playbackModeState: PlaybackModeState? = nil,
        evictAfterSkips: Int,
        in context: ModelContext
    ) throws -> [TrackSummaryPresentation] {
        let items = try PlaylistItemRepository.playableItems(forPlaylistID: playlistID, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        let tracksByID = tracks.firstValueDictionary(keyedBy: \.id)
        let orderedItems = playbackModeState.map {
            PlaylistDisplayOrder.orderedItems(items, state: $0)
        } ?? items.sorted(by: areItemsInPlaylistOrder)

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
                isPlayable: item.isPlayable,
                healthStatus: TrackHealthStatus.resolve(
                    skipCount: item.skipCount,
                    evictAfterSkips: evictAfterSkips,
                    isEvicted: item.evictedAt != nil,
                    isProtected: item.protected
                )
            )
        }
    }

    private static func areItemsInPlaylistOrder(_ left: PlaylistItemRecord, _ right: PlaylistItemRecord) -> Bool {
        if left.sortOrder != right.sortOrder {
            return left.sortOrder < right.sortOrder
        }

        return left.createdAt < right.createdAt
    }
}
