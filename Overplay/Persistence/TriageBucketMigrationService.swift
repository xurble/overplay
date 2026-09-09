import Foundation
import SwiftData

/// Moves pre-bucket triage data onto the single shared triage bucket.
///
/// This device holds the only existing Overplay dataset, so the migration
/// makes a best effort to preserve stats and merge counts — but a consistent
/// database matters more than rescuing every number, and it deliberately
/// stops short of a versioned schema.
///
/// It is **idempotent and derived from stored state** rather than guarded by
/// a local flag. `roleRawValue` is a plain `String`, so retiring the `triage`
/// role is a data change and not a schema change: a legacy row keeps
/// `"triage"` on disk until this runs. A flag would be lost by a reinstall
/// while the CloudKit-backed rows survived, which is exactly the case that
/// must not silently leave items parented to a playlist nothing reads.
enum TriageBucketMigrationService {
    struct Outcome: Equatable {
        var migratedSourceCount = 0
        /// Items re-parented onto the bucket keeping their own row.
        var movedItemCount = 0
        /// Items folded into an existing bucket row for the same track.
        var mergedItemCount = 0

        var didChangeAnything: Bool {
            migratedSourceCount > 0 || movedItemCount > 0 || mergedItemCount > 0
        }
    }

    @MainActor
    @discardableResult
    static func migrate(
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws -> Outcome {
        let legacyPlaylists = try PlaylistRepository.allPlaylists(in: context)
            .filter(\.needsTriageBucketMigration)

        guard !legacyPlaylists.isEmpty else {
            return Outcome()
        }

        var outcome = Outcome()
        let bucket = try PlaylistRepository.triageBucket(in: context)
        let migratedAt = Date.now

        // Bucket rows are keyed by track, so this map is what collapses the
        // same song contributed by several playlists into one row.
        var bucketItemsByTrackID = try PlaylistItemRepository
            .items(forPlaylistID: bucket.id, in: context)
            .firstValueDictionary(keyedBy: \.trackID)

        for legacyPlaylist in legacyPlaylists {
            let sourceMusicPlaylistID = legacyPlaylist.musicPlaylistID

            for item in try PlaylistItemRepository.items(forPlaylistID: legacyPlaylist.id, in: context) {
                if let keeper = bucketItemsByTrackID[item.trackID], keeper !== item {
                    PlaylistItemRepository.mergeStats(
                        from: item,
                        into: keeper,
                        adoptEvictionStateIfNewer: true
                    )
                    keeper.addSourceMusicPlaylistID(sourceMusicPlaylistID)
                    keeper.updatedAt = migratedAt
                    context.delete(item)
                    outcome.mergedItemCount += 1
                    continue
                }

                item.playlistID = bucket.id
                item.addSourceMusicPlaylistID(sourceMusicPlaylistID)
                item.updatedAt = migratedAt
                bucketItemsByTrackID[item.trackID] = item
                outcome.movedItemCount += 1
            }

            legacyPlaylist.role = .triageSource
            legacyPlaylist.updatedAt = migratedAt
            outcome.migratedSourceCount += 1
        }

        rekeyDeviceLocalPlaybackState(
            migratedMusicPlaylistIDs: legacyPlaylists.map(\.musicPlaylistID),
            bucketMusicPlaylistID: bucket.musicPlaylistID,
            defaults: defaults
        )

        try context.save()
        return outcome
    }

    /// Device-local playback state is keyed by `musicPlaylistID`, so a restore
    /// point captured against a former triage playlist would point at a
    /// record that no longer owns any items.
    ///
    /// Only the playlist playback was actually restored against is rekeyed.
    /// Rewriting all of them would collide on the bucket's single key and let
    /// the last one processed clobber the rest — and the rest are inert
    /// anyway, since nothing keys on those IDs once the roles change.
    private static func rekeyDeviceLocalPlaybackState(
        migratedMusicPlaylistIDs: [String],
        bucketMusicPlaylistID: String,
        defaults: UserDefaults
    ) {
        guard let restoredPlaylistID = LocalPlaybackStateStore.load(from: defaults)?.playlistID,
              migratedMusicPlaylistIDs.contains(restoredPlaylistID) else {
            return
        }

        LocalPlaybackStateStore.rekeyMusicPlaylistID(
            from: restoredPlaylistID,
            to: bucketMusicPlaylistID,
            from: defaults
        )
        PlaybackIdentityStore.rekeyMusicPlaylistID(
            from: restoredPlaylistID,
            to: bucketMusicPlaylistID,
            from: defaults
        )
        PlaybackOrderStore.rekeyMusicPlaylistID(
            from: restoredPlaylistID,
            to: bucketMusicPlaylistID,
            from: defaults
        )
    }
}
