import Foundation
import SwiftData

enum TrackOwnershipMigrationService {
    struct Outcome: Equatable {
        var mergedCount = 0
        var migratedCount = 0
        var deletedCount = 0
    }

    @discardableResult
    static func migrate(in context: ModelContext) throws -> Outcome {
        let bucket = try PlaylistRepository.triageBucket(in: context)
        var outcome = Outcome()
        for item in try PlaylistItemRepository.allItems(in: context) where !item.isDeleted {
            if item.evictedAt != nil, item.playlistID != bucket.id {
                if let owner = try PlaylistRepository.playlist(id: item.playlistID, in: context),
                   owner.role == .oneTruePlaylist {
                    if !item.suppressedOTPMusicPlaylistIDs.contains(owner.musicPlaylistID) {
                        item.suppressedOTPMusicPlaylistIDs.append(owner.musicPlaylistID)
                    }
                }
                item.playlistID = bucket.id
                item.musicPlaylistEntryID = nil
            }
        }
        outcome.mergedCount = try PlaylistItemRepository.mergeDuplicateItems(in: context, save: false)
        let linkedSourceIDs = Set(try PlaylistRepository.triageSources(in: context).map(\.musicPlaylistID))
        for item in try PlaylistItemRepository.allItems(in: context) where !item.isDeleted {
            if item.ownershipVersion > 0, item.pendingRetentionCleanup {
                item.pendingRetentionCleanup = false
                if try TrackRetentionPolicy.deleteIfUnowned(item, in: context) {
                    outcome.deletedCount += 1
                    continue
                }
            }
            guard item.ownershipVersion == 0 else { continue }
            item.sourceMusicPlaylistIDs.removeAll { !linkedSourceIDs.contains($0) }
            item.hasRecordedActivity = item.hasListeningHistory
            item.ownershipVersion = 1
            outcome.migratedCount += 1
            if try TrackRetentionPolicy.deleteIfUnowned(item, legacyCleanup: true, in: context) {
                outcome.deletedCount += 1
            }
        }
        try context.save()
        for playlist in try PlaylistRepository.allPlaylists(in: context) where !playlist.isTriageBucket {
            PlaybackOrderStore.mergeMusicPlaylistID(
                from: PlaylistPlaybackScope.retired.playbackOrderPlaylistID(for: playlist.musicPlaylistID),
                to: PlaylistPlaybackScope.retired.playbackOrderPlaylistID(for: bucket.musicPlaylistID)
            )
        }
        return outcome
    }
}
