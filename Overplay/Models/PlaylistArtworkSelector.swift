import Foundation

enum PlaylistArtworkSelector {
    static func representativeArtworkURL(
        for playlist: PlaylistRecord,
        items: [PlaylistItemRecord],
        tracksByID: [UUID: TrackRecord]
    ) -> String? {
        items
            .filter { $0.playlistID == playlist.id && $0.isPlayable }
            .sorted { left, right in
                if left.sortOrder != right.sortOrder {
                    return left.sortOrder < right.sortOrder
                }
                return left.createdAt < right.createdAt
            }
            .lazy
            .compactMap { tracksByID[$0.trackID]?.artworkURLTemplate }
            .first { !$0.isEmpty }
    }
}
