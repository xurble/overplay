import Foundation
@preconcurrency import MusicKit
import SwiftData

struct PlaybackQueueEntry {
    var localTrackID: String
    var musicTrack: Track
}

enum PlaybackQueueCoordinator {
    static func queueTracks(from entries: [PlaybackQueueEntry], fallback tracks: [Track]) -> [Track] {
        entries.isEmpty ? tracks : entries.map(\.musicTrack)
    }

    static func musicTracksByLocalID(
        _ tracks: [Track],
        tracksByID: [UUID: TrackRecord]
    ) -> [String: Track] {
        PlaybackQueueBuilder.musicTracksByLocalID(tracks, tracksByID: tracksByID)
    }

    static func cachedEntries(
        orderedTrackIDs: [String],
        tracksByID: [UUID: TrackRecord]
    ) -> [PlaybackQueueEntry] {
        orderedTrackIDs.compactMap { localTrackID in
            cachedEntry(localTrackID: localTrackID, tracksByID: tracksByID)
        }
    }

    static func cachedEntry(
        localTrackID: String,
        tracksByID: [UUID: TrackRecord]
    ) -> PlaybackQueueEntry? {
        guard let trackID = UUID(uuidString: localTrackID),
              let trackRecord = tracksByID[trackID],
              let playbackData = trackRecord.musicKitPlaybackData,
              let musicTrack = try? JSONDecoder().decode(Track.self, from: playbackData) else {
            return nil
        }

        return PlaybackQueueEntry(localTrackID: localTrackID, musicTrack: musicTrack)
    }

    static func localTrackID(matching musicItemID: String, context: ModelContext) throws -> String? {
        if let trackID = try TrackRecordRepository.track(musicItemID: musicItemID, in: context)?.id.uuidString {
            return trackID
        }

        let tracks = try TrackRecordRepository.allTracks(in: context)
        return PlaybackQueueBuilder.localTrackID(
            matching: musicItemID,
            tracksByID: tracks.firstValueDictionary(keyedBy: \.id)
        )
    }

    static func transitionEntries(
        from entries: [PlaybackQueueEntry],
        startingAt localTrackID: String
    ) -> [PlaybackQueueEntry] {
        guard let index = entries.firstIndex(where: { $0.localTrackID == localTrackID }) else {
            return entries
        }

        return Array(entries[index...])
    }

    static func activeQueueState(
        entries: [PlaybackQueueEntry],
        startingAt localTrackID: String?
    ) -> (localTrackIDs: [String], index: Int?) {
        let localTrackIDs = entries.map(\.localTrackID)
        guard !localTrackIDs.isEmpty else {
            return ([], nil)
        }

        let index = localTrackID
            .flatMap { localTrackIDs.firstIndex(of: $0) }
            ?? localTrackIDs.startIndex
        return (localTrackIDs, index)
    }

    static func updatedActiveQueueIndex(
        localTrackID: String?,
        activeQueueLocalTrackIDs: [String],
        currentIndex: Int?
    ) -> Int? {
        guard let localTrackID,
              let index = activeQueueLocalTrackIDs.firstIndex(of: localTrackID) else {
            return currentIndex
        }

        return index
    }

    static func advancedActiveQueueIndex(
        by offset: Int,
        activeQueueLocalTrackIDs: [String],
        currentIndex: Int?
    ) -> Int? {
        guard let currentIndex else { return nil }
        let newIndex = currentIndex + offset
        guard activeQueueLocalTrackIDs.indices.contains(newIndex) else {
            return nil
        }

        return newIndex
    }
}
