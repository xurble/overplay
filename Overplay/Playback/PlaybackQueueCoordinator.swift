import Foundation
@preconcurrency import MusicKit
import SwiftData

struct PlaybackQueueEntry {
    var playlistItemID: UUID
    var localTrackID: String
    var queuedMusicItemID: String
    var musicTrack: Track
}

struct RealizedPlaybackQueueEntry: Equatable {
    var queueEntryID: String
    var playlistItemID: UUID
    var localTrackID: String
    var queuedMusicItemID: String
}

struct PlaybackQueueMaterialization {
    var queueEntries: [MusicPlayer.Queue.Entry]
    var realizedEntries: [RealizedPlaybackQueueEntry]
    var startingEntry: MusicPlayer.Queue.Entry?
}

enum PlaybackQueueMaterializer {
    static func materialize(
        _ entries: [PlaybackQueueEntry],
        startingAt localTrackID: String?
    ) -> PlaybackQueueMaterialization {
        var queueEntries: [MusicPlayer.Queue.Entry] = []
        var realizedEntries: [RealizedPlaybackQueueEntry] = []
        var startingEntry: MusicPlayer.Queue.Entry?

        for entry in entries {
            let queueEntry = MusicPlayer.Queue.Entry(entry.musicTrack)
            queueEntries.append(queueEntry)
            realizedEntries.append(RealizedPlaybackQueueEntry(
                queueEntryID: queueEntry.id,
                playlistItemID: entry.playlistItemID,
                localTrackID: entry.localTrackID,
                queuedMusicItemID: entry.queuedMusicItemID
            ))

            if entry.localTrackID == localTrackID {
                startingEntry = queueEntry
            }
        }

        return PlaybackQueueMaterialization(
            queueEntries: queueEntries,
            realizedEntries: realizedEntries,
            startingEntry: startingEntry
        )
    }
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
        itemsByTrackID: [UUID: PlaylistItemRecord],
        tracksByID: [UUID: TrackRecord]
    ) -> [PlaybackQueueEntry] {
        orderedTrackIDs.compactMap { localTrackID in
            cachedEntry(localTrackID: localTrackID, itemsByTrackID: itemsByTrackID, tracksByID: tracksByID)
        }
    }

    static func cachedEntry(
        localTrackID: String,
        itemsByTrackID: [UUID: PlaylistItemRecord],
        tracksByID: [UUID: TrackRecord]
    ) -> PlaybackQueueEntry? {
        guard let trackID = UUID(uuidString: localTrackID),
              let item = itemsByTrackID[trackID],
              let trackRecord = tracksByID[trackID],
              let playbackData = trackRecord.musicKitPlaybackData,
              let musicTrack = try? JSONDecoder().decode(Track.self, from: playbackData) else {
            return nil
        }

        return PlaybackQueueEntry(
            playlistItemID: item.id,
            localTrackID: localTrackID,
            queuedMusicItemID: musicTrack.id.rawValue,
            musicTrack: musicTrack
        )
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
        entries: [RealizedPlaybackQueueEntry],
        startingAt localTrackID: String?
    ) -> (entries: [RealizedPlaybackQueueEntry], index: Int?) {
        guard !entries.isEmpty else {
            return ([], nil)
        }

        let index = localTrackID
            .flatMap { localTrackID in
                entries.firstIndex { $0.localTrackID == localTrackID }
            }
            ?? entries.startIndex
        return (entries, index)
    }

    static func updatedActiveQueueIndex(
        localTrackID: String?,
        activeQueueEntries: [RealizedPlaybackQueueEntry],
        currentIndex: Int?
    ) -> Int? {
        guard let localTrackID,
              let index = activeQueueEntries.firstIndex(where: { $0.localTrackID == localTrackID }) else {
            return currentIndex
        }

        return index
    }

    static func advancedActiveQueueIndex(
        by offset: Int,
        activeQueueEntries: [RealizedPlaybackQueueEntry],
        currentIndex: Int?
    ) -> Int? {
        guard let currentIndex else { return nil }
        let newIndex = currentIndex + offset
        guard activeQueueEntries.indices.contains(newIndex) else {
            return nil
        }

        return newIndex
    }

    /// Index reconciliation after a user-initiated next/previous. The
    /// player-reported entry wins when it already moved off the
    /// pre-transition track; otherwise advance optimistically from the
    /// pre-transition index, never blindly from the current one, which a
    /// concurrent refresh may already have moved. An out-of-bounds advance
    /// keeps the pre-transition index (skipping back on the first track
    /// restarts it rather than leaving the queue position unknown).
    static func reconciledTransitionIndex(
        playerReportedEntryID: String?,
        activeQueueEntries: [RealizedPlaybackQueueEntry],
        preTransitionIndex: Int?,
        offset: Int
    ) -> Int? {
        let optimisticIndex = advancedActiveQueueIndex(
            by: offset,
            activeQueueEntries: activeQueueEntries,
            currentIndex: preTransitionIndex
        ) ?? preTransitionIndex

        guard let playerReportedEntryID,
              let realizedIndex = activeQueueEntries.firstIndex(where: { $0.queueEntryID == playerReportedEntryID }),
              realizedIndex != preTransitionIndex else {
            return optimisticIndex
        }

        return realizedIndex
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
