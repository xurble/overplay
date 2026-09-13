import Foundation

/// An occurrence is source metadata, never a second membership/statistics row.
struct PlaylistEntryProvenance: Codable, Equatable, Sendable {
    var playlistID: String
    var entryID: String?
    var position: Int?
    var musicItemID: String
    var isrc: String?
    var playCount: Int?
    var lastPlayedDate: Date?
    var observedAt: Date

    init(snapshot: TrackSnapshot, playlistID: String, observedAt: Date) {
        self.playlistID = playlistID
        entryID = snapshot.playlistEntryID
        position = snapshot.remotePosition
        musicItemID = snapshot.id
        isrc = snapshot.isrc
        playCount = snapshot.entryPlayCount
        lastPlayedDate = snapshot.entryLastPlayedDate
        self.observedAt = observedAt
    }

    /// Missing entry IDs remain explicitly missing. Position only distinguishes
    /// observations in a fetched playlist; it is not a durable playback identity.
    nonisolated func isSameOccurrence(as other: Self) -> Bool {
        playlistID == other.playlistID && entryID == other.entryID
            && (entryID != nil || (position == other.position && musicItemID == other.musicItemID))
    }

    nonisolated static func merging(_ observations: [Self]) -> [Self] {
        var result: [Self] = []
        for observation in observations {
            if let index = result.firstIndex(where: { $0.isSameOccurrence(as: observation) }) {
                if observation.observedAt > result[index].observedAt { result[index] = observation }
            } else { result.append(observation) }
        }
        return result
    }

    var playbackEvidence: MusicLibraryPlaybackSnapshot {
        MusicLibraryPlaybackSnapshot(musicItemID: musicItemID, playCount: playCount,
                                     lastPlayedDate: lastPlayedDate, playlistEntryEvidence: true)
    }
}
