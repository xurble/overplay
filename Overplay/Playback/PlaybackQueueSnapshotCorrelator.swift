import Foundation
@preconcurrency import MusicKit

/// Metadata is corroborating playback evidence, never a canonical song identity.
struct PlaybackTrackMatchMetadata: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var duration: Double?

    init(title: String, artist: String, duration: Double? = nil) {
        func normalized(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        self.title = normalized(title)
        self.artist = normalized(artist)
        self.duration = duration
    }

    func matches(_ other: Self) -> Bool {
        guard !title.isEmpty, !artist.isEmpty, title == other.title, artist == other.artist else { return false }
        if let duration, let otherDuration = other.duration {
            return duration.isFinite && otherDuration.isFinite && abs(duration - otherDuration) <= 2
        }
        return true
    }
}

/// One hydrated entry of the player's live queue.
struct PlayerQueueEntrySnapshot: Equatable, Sendable {
    var id: String
    var musicItemID: String?
    var metadata: PlaybackTrackMatchMetadata?

    init(id: String, musicItemID: String?, metadata: PlaybackTrackMatchMetadata? = nil) {
        self.id = id
        self.musicItemID = musicItemID
        self.metadata = metadata
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
    /// The matchable IDs supplied only by the runtime alias store. Retained
    /// for diagnostics so a successful rebuild can prove it used an alias.
    var runtimeAliasMusicItemIDs: Set<String> = []
    var metadata: PlaybackTrackMatchMetadata?
    /// Only the actual submitted manifest is eligible for new metadata matches.
    var wasSubmitted = false
    var cachedAssociations: [String: PlaybackTrackMatchMetadata] = [:]

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
/// Known song IDs take priority. Reissued IDs can also be recovered from the
/// submitted manifest or validated playback associations.
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

    /// Rebuilds correlation from the queue the player is actually holding,
    /// in the player's own order.
    ///
    /// `realizedEntries(expected:snapshots:)` above answers "did the player
    /// accept what Overplay handed it", so it walks the expected members.
    /// This answers the opposite question — "what is the player holding" —
    /// which is what matters once the player has re-issued entry IDs of its
    /// own accord: a mode change that reorders the queue, or a queue Apple
    /// Music re-materialized. Correlating from the live snapshot recovers
    /// the playlist context instead of reading as a diverged transition.
    ///
    /// Each member is claimed at most once, because Overplay forbids
    /// duplicate songs within a playlist.
    static func realizedEntriesInPlayerOrder(
        snapshots: [PlayerQueueEntrySnapshot],
        members: [PendingQueueCorrelation],
        allowPositionMatching: Bool = false,
        submittedLocalTrackIDs: [String] = []
    ) -> [RealizedPlaybackQueueEntry] {
        var matches: [Int: (PendingQueueCorrelation, PlaybackQueueMatchSource)] = [:]
        var claimed = Set<String>()
        // Resolve IDs first across the complete snapshot. An earlier metadata
        // guess must never steal a later entry's documented identity.
        for (index, snapshot) in snapshots.enumerated() {
            guard let id = snapshot.musicItemID else { continue }
            let candidates = members.filter { $0.matches(id) }
            guard candidates.count == 1, let member = candidates.first,
                  claimed.insert(member.localTrackID).inserted else { continue }
            matches[index] = (member, .identifier)
        }
        // Playlist membership includes retired and otherwise nonqueued rows.
        // Only the exact handoff order can prove positions; missing or changed
        // submitted members must invalidate that proof rather than shorten it.
        let membersByID = members.firstValueDictionary(keyedBy: \.localTrackID)
        let submittedMembers = submittedLocalTrackIDs.compactMap { membersByID[$0] }
        let hasIDAnchor = !matches.isEmpty
        let positionsAgree = snapshots.count == submittedLocalTrackIDs.count && hasIDAnchor
            && submittedMembers.count == submittedLocalTrackIDs.count
            && Set(submittedLocalTrackIDs).count == submittedLocalTrackIDs.count
            && submittedMembers.allSatisfy(\.wasSubmitted)
            && matches.allSatisfy { submittedMembers[$0.key].localTrackID == $0.value.0.localTrackID }
            && zip(snapshots, submittedMembers).allSatisfy { snapshot, member in
                snapshot.metadata.map { member.metadata?.matches($0) == true } == true
            }

        for (index, snapshot) in snapshots.enumerated() where matches[index] == nil {
            guard let id = snapshot.musicItemID, let metadata = snapshot.metadata else { continue }
            // Conflicting known IDs cannot be rehabilitated through metadata.
            guard !members.contains(where: { $0.matches(id) }),
                  snapshots.filter({ $0.musicItemID == id }).count == 1 else { continue }
            let candidates = members.filter { $0.metadata?.matches(metadata) == true }
            let member: PendingQueueCorrelation
            let source: PlaybackQueueMatchSource
            if candidates.count == 1, let unique = candidates.first,
               unique.wasSubmitted || unique.cachedAssociations[id]?.matches(metadata) == true {
                member = unique
                source = unique.cachedAssociations[id]?.matches(metadata) == true ? .cachedAssociation : .metadata
            } else if allowPositionMatching, positionsAgree,
                      candidates.contains(where: { $0.localTrackID == submittedMembers[index].localTrackID }) {
                member = submittedMembers[index]
                source = .positionAndMetadata
            } else {
                continue
            }
            // Count against ALL candidates, not just unclaimed ones: a duplicate
            // title/artist is still ambiguous after another candidate was claimed.
            guard claimed.insert(member.localTrackID).inserted else { continue }
            matches[index] = (member, source)
        }
        return snapshots.enumerated().compactMap { index, snapshot in
            guard let (member, source) = matches[index], let musicItemID = snapshot.musicItemID else { return nil }
            return RealizedPlaybackQueueEntry(
                queueEntryID: snapshot.id,
                playlistItemID: member.playlistItemID,
                localTrackID: member.localTrackID,
                queuedMusicItemID: musicItemID,
                matchSource: source
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
        wasSubmitted = true
        metadata = PlaybackTrackMatchMetadata(
            title: entry.musicTrack.title, artist: entry.musicTrack.artistName, duration: entry.musicTrack.duration
        )
    }
}

extension PlayerQueueEntrySnapshot {
    init(entry: MusicPlayer.Queue.Entry, item: MusicPlayer.Queue.Entry.Item?) {
        let metadata: PlaybackTrackMatchMetadata?
        if case let .song(song) = item {
            metadata = PlaybackTrackMatchMetadata(title: song.title, artist: song.artistName, duration: song.duration)
        } else {
            metadata = nil
        }
        self.init(id: entry.id, musicItemID: item?.id.rawValue, metadata: metadata)
    }
}
