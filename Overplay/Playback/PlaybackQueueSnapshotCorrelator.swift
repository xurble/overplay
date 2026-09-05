import Foundation
@preconcurrency import MusicKit

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
    /// Every Apple Music ID this member may legitimately be reported under.
    ///
    /// Apple Music owns the entries created by a queue insert, and can report
    /// one under the other ID domain than the track was queued with — a
    /// library ID for a catalog track, or the reverse. Matching on the queued
    /// ID alone silently drops those entries, so `MusicTrackIdentity` supplies
    /// both domains here.
    var matchableMusicItemIDs: Set<String>

    init(
        playlistItemID: UUID,
        localTrackID: String,
        queuedMusicItemID: String,
        matchableMusicItemIDs: Set<String>? = nil
    ) {
        self.playlistItemID = playlistItemID
        self.localTrackID = localTrackID
        self.queuedMusicItemID = queuedMusicItemID
        self.matchableMusicItemIDs = matchableMusicItemIDs ?? [queuedMusicItemID]
    }

    func matches(_ musicItemID: String) -> Bool {
        matchableMusicItemIDs.contains(musicItemID)
    }
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
        var availableSnapshots = snapshots.filter { snapshot in
            snapshot.musicItemID != nil && !reservedEntryIDs.contains(snapshot.id)
        }

        return expected.compactMap { member in
            guard let index = availableSnapshots.firstIndex(where: { snapshot in
                snapshot.musicItemID.map(member.matches) == true
            }) else {
                return nil
            }

            let snapshot = availableSnapshots.remove(at: index)
            return RealizedPlaybackQueueEntry(
                queueEntryID: snapshot.id,
                playlistItemID: member.playlistItemID,
                localTrackID: member.localTrackID,
                queuedMusicItemID: snapshot.musicItemID ?? member.queuedMusicItemID
            )
        }
    }
}

extension PendingQueueCorrelation {
    init(entry: PlaybackQueueEntry) {
        let ids = MusicTrackIdentity.ids(for: entry.musicTrack)
        self.init(
            playlistItemID: entry.playlistItemID,
            localTrackID: entry.localTrackID,
            queuedMusicItemID: entry.queuedMusicItemID,
            matchableMusicItemIDs: Set([entry.queuedMusicItemID, ids.catalogID, ids.libraryID].compactMap { $0 })
        )
    }
}
