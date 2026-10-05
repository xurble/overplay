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
        /// Bucket records activated or hidden while choosing one keeper.
        var normalizedBucketCount = 0
        var migratedSourceCount = 0
        /// Items re-parented onto the bucket keeping their own row.
        var movedItemCount = 0
        /// Items folded into an existing bucket row for the same track.
        var mergedItemCount = 0
        /// History events retargeted so playlist context and Restore survive.
        var reparentedHistoryEventCount = 0

        var didChangeAnything: Bool {
            createdBucket || normalizedBucketCount > 0 || migratedSourceCount > 0
                || movedItemCount > 0 || mergedItemCount > 0
                || reparentedHistoryEventCount > 0
        }
    }

    @MainActor
    @discardableResult
    static func migrate(
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws -> Outcome {
        let playlists = try PlaylistRepository.allPlaylists(in: context)
        let triageItemOwners = playlists.filter {
            $0.needsTriageBucketMigration
                || $0.roleRawValue == PlaylistRole.triageSource.rawValue
        }
        let convergence = try PlaylistRepository.convergeTriageBuckets(in: context)
        var outcome = Outcome(
            createdBucket: convergence.createdBucket,
            normalizedBucketCount: convergence.normalizedBucketCount,
            movedItemCount: convergence.movedItemCount,
            mergedItemCount: convergence.mergedItemCount,
            reparentedHistoryEventCount: convergence.reparentedHistoryEventCount
        )
        let bucket = convergence.bucket
        let migratedAt = Date.now

        // A CloudKit import can deliver a pre-bucket item's row after this
        // device has already converted its parent to `.triageSource`. Sweep
        // every source owner on every pass, not only parents still carrying
        // the legacy raw role. Inactive sources stay unattributed, matching
        // unlink semantics.
        for sourcePlaylist in triageItemOwners {
            let reparentSummary = if sourcePlaylist.isActive {
                try PlaylistItemRepository.reparentItems(
                    from: sourcePlaylist.id,
                    to: bucket.id,
                    sourceMusicPlaylistID: sourcePlaylist.musicPlaylistID,
                    in: context
                )
            } else {
                try PlaylistItemRepository.reparentItems(
                    from: sourcePlaylist.id,
                    to: bucket.id,
                    in: context
                )
            }
            outcome.movedItemCount += reparentSummary.movedCount
            outcome.mergedItemCount += reparentSummary.mergedCount
            outcome.reparentedHistoryEventCount += try EventRepository.reparentEvents(
                from: sourcePlaylist.id,
                to: bucket.id,
                in: context
            )

            if sourcePlaylist.needsTriageBucketMigration {
                sourcePlaylist.role = .triageSource
                sourcePlaylist.updatedAt = migratedAt
                outcome.migratedSourceCount += 1
            }
        }

        if outcome.didChangeAnything {
            try context.save()
        }
        return outcome
    }
}
