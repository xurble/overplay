import Foundation

enum PlaybackQueueBuilder {
    static func playableMusicItemIDs(
        items: [PlaylistItemRecord],
        tracksByID: [UUID: TrackRecord]
    ) -> Set<String> {
        Set(items.flatMap { item in
            guard item.isPlayable, let track = tracksByID[item.trackID] else {
                return [String]()
            }

            return musicItemIDs(for: track)
        })
    }

    static func playlistItem(
        matching musicItemID: String,
        items: [PlaylistItemRecord],
        tracksByID: [UUID: TrackRecord]
    ) -> PlaylistItemRecord? {
        items.first { item in
            guard let track = tracksByID[item.trackID] else {
                return false
            }

            return musicItemIDs(for: track).contains(musicItemID)
        }
    }

    static func trackRecord(
        matching musicItemID: String,
        tracks: [TrackRecord]
    ) -> TrackRecord? {
        tracks.first { track in
            musicItemIDs(for: track).contains(musicItemID)
        }
    }

    static func musicItemIDs(for track: TrackRecord) -> [String] {
        [track.catalogID, track.libraryID].compactMap { $0 }
    }
}
