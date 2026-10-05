import Foundation
@preconcurrency import MusicKit

enum PlaybackQueueBuilder {
    static func cachedPlayableMusicTracks(
        items: [PlaylistItemRecord],
        tracksByID: [UUID: TrackRecord],
        scope: PlaylistPlaybackScope = .active
    ) -> [Track] {
        items.compactMap { item in
            guard scope.includes(item),
                  let track = tracksByID[item.trackID],
                  let playbackData = track.musicKitPlaybackData else {
                return nil
            }

            return try? JSONDecoder().decode(Track.self, from: playbackData)
        }
    }

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

    /// Every Apple Music identifier a track may be reported under.
    static func musicItemIDs(for track: TrackRecord) -> [String] {
        var ids = Array(Set([track.catalogID, track.libraryID].compactMap { $0 } + track.identityAliases))

        if !track.hasDocumentedIdentity, let playbackData = track.musicKitPlaybackData,
           let musicTrack = try? JSONDecoder().decode(Track.self, from: playbackData) {
            let identity = MusicTrackIdentity.ids(for: musicTrack)
            for candidate in [musicTrack.id.rawValue, identity.catalogID, identity.libraryID].compactMap({ $0 })
            where !ids.contains(candidate) {
                ids.append(candidate)
            }
        }

        return ids
    }
}
