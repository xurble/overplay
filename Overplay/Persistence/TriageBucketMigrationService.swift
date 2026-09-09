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
        var createdBucket = false
        /// Duplicate buckets folded into the deterministic keeper after sync.
        var consolidatedBucketCount = 0
        var migratedSourceCount = 0
        /// Items re-parented onto the bucket keeping their own row.
        var movedItemCount = 0
        /// Items folded into an existing bucket row for the same track.
        var mergedItemCount = 0

        var didChangeAnything: Bool {
            createdBucket || consolidatedBucketCount > 0 || migratedSourceCount > 0
                || movedItemCount > 0 || mergedItemCount > 0
        }
    }

    @MainActor
    @discardableResult
    static func migrate(
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws -> Outcome {
        let playlists = try PlaylistRepository.allPlaylists(in: context)
        let legacyPlaylists = playlists
            .filter(\.needsTriageBucketMigration)
        let bucketCount = playlists.count(where: \.isTriageBucket)
        var outcome = Outcome(
            createdBucket: bucketCount == 0,
            consolidatedBucketCount: max(bucketCount - 1, 0)
        )
        let bucket = try PlaylistRepository.triageBucket(in: context)

        guard !legacyPlaylists.isEmpty else {
            if outcome.didChangeAnything {
                try context.save()
            }
            return outcome
        }

        let migratedAt = Date.now

        for legacyPlaylist in legacyPlaylists {
            let sourceMusicPlaylistID = legacyPlaylist.musicPlaylistID
            let reparentSummary = try PlaylistItemRepository.reparentItems(
                from: legacyPlaylist.id,
                to: bucket.id,
                sourceMusicPlaylistID: sourceMusicPlaylistID,
                in: context
            )
            outcome.movedItemCount += reparentSummary.movedCount
            outcome.mergedItemCount += reparentSummary.mergedCount

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
