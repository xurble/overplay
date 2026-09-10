import Foundation
import SwiftData

enum TrackRetentionPolicy {
    /// Device-local leases let every cleanup path (including background sync)
    /// defer to the shared playback session without persisting a playing flag.
    final class PlaybackLease {
        var itemID: UUID?
        var trackID: UUID?
    }
    private struct WeakLease {
        weak var value: PlaybackLease?
    }
    private static var playbackLeases: [WeakLease] = []

    static func makePlaybackLease() -> PlaybackLease {
        playbackLeases.removeAll { $0.value == nil }
        let lease = PlaybackLease()
        playbackLeases.append(WeakLease(value: lease))
        return lease
    }

    static func rekeyPlaybackTracks(_ mapping: [String: String]) {
        for lease in playbackLeases.compactMap(\.value) {
            if let trackID = lease.trackID, let replacement = mapping[trackID.uuidString] {
                lease.trackID = UUID(uuidString: replacement)
            }
        }
    }

    static func shouldDelete(_ item: PlaylistItemRecord, legacyCleanup: Bool = false) -> Bool {
        guard item.sourceMusicPlaylistIDs.isEmpty,
              item.suppressedOTPMusicPlaylistIDs.isEmpty,
              item.skipCount == 0, item.playthroughCount == 0 else { return false }
        if item.evictedAt != nil { return true }
        guard !item.isExplicitlyKept else { return false }
        return legacyCleanup || !item.hasListeningHistory
    }

    @discardableResult
    static func deleteIfUnowned(
        _ item: PlaylistItemRecord,
        protectingItemID: UUID? = nil,
        legacyCleanup: Bool = false,
        in context: ModelContext
    ) throws -> Bool {
        guard !item.isDeleted,
              let owner = try PlaylistRepository.playlist(id: item.playlistID, in: context),
              owner.isTriageBucket,
              shouldDelete(item, legacyCleanup: legacyCleanup) else { return false }
        if item.id == protectingItemID || playbackLeases.contains(where: {
            $0.value?.itemID == item.id || $0.value?.trackID == item.trackID
        }) {
            item.pendingRetentionCleanup = true
            return false
        }
        if let retiredAt = item.evictedAt {
            for source in try PlaylistRepository.triageSources(in: context) {
                let linkedAt = source.triageLinkedAt ?? source.createdAt
                let initialImportPending = source.lastSyncedAt.map { $0 < linkedAt } ?? true
                guard retiredAt >= linkedAt,
                      initialImportPending || PlaylistSyncService.hasActiveSourceRead(source.id) else { continue }
                if !source.triageExcludedTrackIDs.contains(item.trackID.uuidString) {
                    source.triageExcludedTrackIDs.append(item.trackID.uuidString)
                }
            }
        }
        context.delete(item)
        return true
    }
}
