import Foundation
@preconcurrency import MusicKit

enum PlaybackQueueBuilder {
    static func playbackOrderTracks(
        items: [PlaylistItemRecord],
        scope: PlaylistPlaybackScope = .active
    ) -> [PlaybackOrderTrack] {
        items.map { item in
            PlaybackOrderTrack(
                id: item.trackID.uuidString,
                createdAt: item.createdAt,
                isPlayable: scope.includes(item)
            )
        }
    }

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

    static func trackRecord(
        matching musicItemID: String,
        tracks: [TrackRecord]
    ) -> TrackRecord? {
        tracks.first { track in
            musicItemIDs(for: track).contains(musicItemID)
        }
    }

    static func musicItemIDs(for track: TrackRecord) -> [String] {
        var ids = [track.catalogID, track.libraryID].compactMap { $0 }

        if let playbackData = track.musicKitPlaybackData,
           let musicTrack = try? JSONDecoder().decode(Track.self, from: playbackData) {
            let identity = MusicTrackIdentity.ids(for: musicTrack)
            for candidate in [musicTrack.id.rawValue, identity.catalogID, identity.libraryID].compactMap({ $0 })
            where !ids.contains(candidate) {
                ids.append(candidate)
            }
        }

        return ids
    }

    static func localTrackID(
        matching musicItemID: String,
        tracksByID: [UUID: TrackRecord]
    ) -> String? {
        tracksByID.first { _, track in
            musicItemIDs(for: track).contains(musicItemID)
        }?.key.uuidString
    }

    static func localTrackID(
        for musicTrack: Track,
        tracksByID: [UUID: TrackRecord]
    ) -> String? {
        localTrackID(matching: musicTrack.id.rawValue, tracksByID: tracksByID)
    }

    static func orderedMusicTracks(
        _ musicTracks: [Track],
        orderedTrackIDs: [String],
        tracksByID: [UUID: TrackRecord]
    ) -> [Track] {
        let musicTracksByLocalID = musicTracksByLocalID(musicTracks, tracksByID: tracksByID)

        return orderedTrackIDs.compactMap { musicTracksByLocalID[$0] }
    }

    static func musicTracksByLocalID(
        _ musicTracks: [Track],
        tracksByID: [UUID: TrackRecord]
    ) -> [String: Track] {
        musicTracks.compactMap { musicTrack in
            localTrackID(for: musicTrack, tracksByID: tracksByID).map { ($0, musicTrack) }
        }
        .firstValueDictionary(keyedBy: \.0, value: \.1)
    }
}
