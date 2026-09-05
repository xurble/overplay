import Foundation

/// One entry of the player's live queue, reduced to the two identifiers
/// Overplay needs to correlate it with local records.
struct PlayerQueueEntrySnapshot: Equatable, Sendable {
    var id: String
    var musicItemID: String?

    init(id: String, musicItemID: String?) {
        self.id = id
        self.musicItemID = musicItemID
    }
}

/// A queue member Overplay expects the player to be holding, without knowing
/// which queue entry ID the player gave it.
struct PendingQueueCorrelation: Equatable, Sendable {
    var playlistItemID: UUID
    var localTrackID: String
    var queuedMusicItemID: String
}

/// Correlates queue entries Overplay did not construct itself.
///
/// `PlaybackQueueMaterializer` knows the entry IDs it builds, but two paths
/// have no such luxury: a top-up batch appended into a live queue, and a
/// mirror playlist queue that Apple Music materializes from a `Playlist`.
/// Both are matched back to local records on Apple Music item ID, which is
/// unique per playlist because Overplay forbids duplicate songs.
enum PlaybackQueueSnapshotCorrelator {
    static func realizedEntries(
        expected: [PendingQueueCorrelation],
        snapshots: [PlayerQueueEntrySnapshot],
        reservedEntryIDs: Set<String> = []
    ) -> [RealizedPlaybackQueueEntry] {
        var availableEntryIDs: [String: [String]] = [:]
        for snapshot in snapshots {
            guard let musicItemID = snapshot.musicItemID,
                  !reservedEntryIDs.contains(snapshot.id) else {
                continue
            }
            availableEntryIDs[musicItemID, default: []].append(snapshot.id)
        }

        return expected.compactMap { member in
            guard var entryIDs = availableEntryIDs[member.queuedMusicItemID],
                  !entryIDs.isEmpty else {
                return nil
            }

            let entryID = entryIDs.removeFirst()
            availableEntryIDs[member.queuedMusicItemID] = entryIDs
            return RealizedPlaybackQueueEntry(
                queueEntryID: entryID,
                playlistItemID: member.playlistItemID,
                localTrackID: member.localTrackID,
                queuedMusicItemID: member.queuedMusicItemID
            )
        }
    }

    /// Correlates in the player's own queue order rather than the caller's.
    ///
    /// The mirror playlist path cares about this: Apple Music decides the
    /// order of the queue it builds from a playlist, so the local view of that
    /// queue should follow the player rather than assert its own sequence.
    static func realizedEntriesInPlayerOrder(
        expected: [PendingQueueCorrelation],
        snapshots: [PlayerQueueEntrySnapshot]
    ) -> [RealizedPlaybackQueueEntry] {
        var membersByMusicItemID: [String: [PendingQueueCorrelation]] = [:]
        for member in expected {
            membersByMusicItemID[member.queuedMusicItemID, default: []].append(member)
        }

        return snapshots.compactMap { snapshot in
            guard let musicItemID = snapshot.musicItemID,
                  var members = membersByMusicItemID[musicItemID],
                  !members.isEmpty else {
                return nil
            }

            let member = members.removeFirst()
            membersByMusicItemID[musicItemID] = members
            return RealizedPlaybackQueueEntry(
                queueEntryID: snapshot.id,
                playlistItemID: member.playlistItemID,
                localTrackID: member.localTrackID,
                queuedMusicItemID: member.queuedMusicItemID
            )
        }
    }
}

extension PendingQueueCorrelation {
    init(entry: PlaybackQueueEntry) {
        self.init(
            playlistItemID: entry.playlistItemID,
            localTrackID: entry.localTrackID,
            queuedMusicItemID: entry.queuedMusicItemID
        )
    }
}
