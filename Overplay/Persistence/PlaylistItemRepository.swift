import Foundation
import SwiftData

enum PlaylistItemRepository {
    struct ReparentSummary: Equatable {
        var movedCount = 0
        var mergedCount = 0
    }

    static func allItems(in context: ModelContext) throws -> [PlaylistItemRecord] {
        let descriptor = FetchDescriptor<PlaylistItemRecord>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor)
    }

    static func items(forPlaylistIDs playlistIDs: [UUID], in context: ModelContext) throws -> [PlaylistItemRecord] {
        guard !playlistIDs.isEmpty else { return [] }

        var result: [PlaylistItemRecord] = []
        result.reserveCapacity(playlistIDs.count)
        for playlistID in playlistIDs {
            result.append(contentsOf: try items(forPlaylistID: playlistID, in: context))
        }
        return result
    }

    static func items(forTrackIDs trackIDs: [UUID], in context: ModelContext) throws -> [PlaylistItemRecord] {
        guard !trackIDs.isEmpty else { return [] }
        return try context.fetch(FetchDescriptor<PlaylistItemRecord>(predicate: #Predicate {
            trackIDs.contains($0.trackID)
        })).filter { !$0.isDeleted }
    }

    static func resetAllStats(in context: ModelContext) throws {
        let items = try allItems(in: context)
        for item in items {
            item.hasRecordedActivity = item.hasListeningHistory
            item.skipCount = 0
            item.playthroughCount = 0
            item.lastPlayedAt = nil
            item.lastSkippedAt = nil
            item.evictedAt = nil
            item.evictionReason = nil
            item.evictionSource = nil
            item.updatedAt = .now
        }

        try context.save()
    }

    static func item(id: UUID, in context: ModelContext) throws -> PlaylistItemRecord? {
        var descriptor = FetchDescriptor<PlaylistItemRecord>(
            predicate: #Predicate { $0.id == id },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).first
    }

    static func item(playlistID: UUID, trackID: UUID, in context: ModelContext) throws -> PlaylistItemRecord? {
        var descriptor = FetchDescriptor<PlaylistItemRecord>(
            predicate: #Predicate {
                $0.playlistID == playlistID && $0.trackID == trackID
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).first
    }

    static func item(trackID: UUID, in context: ModelContext) throws -> PlaylistItemRecord? {
        var descriptor = FetchDescriptor<PlaylistItemRecord>(
            predicate: #Predicate { $0.trackID == trackID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).first { !$0.isDeleted }
    }

    static func items(forPlaylistID playlistID: UUID, in context: ModelContext) throws -> [PlaylistItemRecord] {
        var descriptor = FetchDescriptor<PlaylistItemRecord>(
            predicate: #Predicate { $0.playlistID == playlistID },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }

    static func playableItems(forPlaylistID playlistID: UUID, in context: ModelContext) throws -> [PlaylistItemRecord] {
        var descriptor = FetchDescriptor<PlaylistItemRecord>(
            predicate: #Predicate {
                $0.playlistID == playlistID && $0.evictedAt == nil
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }

    static func activeItems(forPlaylistID playlistID: UUID, in context: ModelContext) throws -> [PlaylistItemRecord] {
        try playableItems(forPlaylistID: playlistID, in: context)
    }

    /// Moves every item from one playlist into another, merging duplicate
    /// tracks and retaining the most recently updated eviction decision.
    /// Item timestamps are deliberately left untouched: they encode the
    /// recency of the user's eviction or restoration intent, not migration
    /// bookkeeping.
    @discardableResult
    static func reparentItems(
        from sourcePlaylistID: UUID,
        to destinationPlaylistID: UUID,
        sourceMusicPlaylistID: String,
        in context: ModelContext
    ) throws -> ReparentSummary {
        try reparentItems(
            from: sourcePlaylistID,
            to: destinationPlaylistID,
            additionalSourceMusicPlaylistID: sourceMusicPlaylistID,
            in: context
        )
    }

    /// Moves items between two local containers without inventing source
    /// provenance. This is used when duplicate triage buckets converge after
    /// CloudKit sync: the rows already carry their contributing playlist IDs.
    @discardableResult
    static func reparentItems(
        from sourcePlaylistID: UUID,
        to destinationPlaylistID: UUID,
        in context: ModelContext
    ) throws -> ReparentSummary {
        try reparentItems(
            from: sourcePlaylistID,
            to: destinationPlaylistID,
            additionalSourceMusicPlaylistID: nil,
            in: context
        )
    }

    private static func reparentItems(
        from sourcePlaylistID: UUID,
        to destinationPlaylistID: UUID,
        additionalSourceMusicPlaylistID: String?,
        in context: ModelContext
    ) throws -> ReparentSummary {
        guard sourcePlaylistID != destinationPlaylistID else { return ReparentSummary() }

        var summary = ReparentSummary()
        var destinationItemsByTrackID = try items(
            forPlaylistID: destinationPlaylistID,
            in: context
        ).firstValueDictionary(keyedBy: \.trackID)

        for item in try items(forPlaylistID: sourcePlaylistID, in: context) {
            if let keeper = destinationItemsByTrackID[item.trackID] {
                mergeStats(from: item, into: keeper, adoptEvictionStateIfNewer: true)
                if let additionalSourceMusicPlaylistID {
                    keeper.addSourceMusicPlaylistID(additionalSourceMusicPlaylistID)
                }
                context.delete(item)
                summary.mergedCount += 1
            } else {
                item.playlistID = destinationPlaylistID
                item.musicPlaylistEntryID = nil
                if let additionalSourceMusicPlaylistID {
                    item.addSourceMusicPlaylistID(additionalSourceMusicPlaylistID)
                }
                destinationItemsByTrackID[item.trackID] = item
                summary.movedCount += 1
            }
        }

        return summary
    }

    @discardableResult
    static func upsert(
        playlistID: UUID,
        trackID: UUID,
        musicPlaylistEntryID: String? = nil,
        sortOrder: Int? = nil,
        in context: ModelContext
    ) throws -> PlaylistItemRecord {
        try upsertWithResult(
            playlistID: playlistID,
            trackID: trackID,
            musicPlaylistEntryID: musicPlaylistEntryID,
            sortOrder: sortOrder,
            in: context
        ).record
    }

    @discardableResult
    static func upsertWithResult(
        playlistID: UUID,
        trackID: UUID,
        musicPlaylistEntryID: String? = nil,
        sortOrder: Int? = nil,
        in context: ModelContext
    ) throws -> PlaylistItemUpsertResult {
        guard let item = try item(trackID: trackID, in: context) else {
            let insertedItem = PlaylistItemRecord(
                playlistID: playlistID,
                trackID: trackID,
                musicPlaylistEntryID: musicPlaylistEntryID,
                sortOrder: sortOrder ?? 0
            )
            context.insert(insertedItem)
            return PlaylistItemUpsertResult(record: insertedItem, mutation: .inserted)
        }

        var didChange = false
        if item.playlistID == playlistID, item.musicPlaylistEntryID != musicPlaylistEntryID {
            item.musicPlaylistEntryID = musicPlaylistEntryID
            didChange = true
        }
        _ = sortOrder
        if didChange {
            item.updatedAt = .now
        }

        return PlaylistItemUpsertResult(
            record: item,
            mutation: didChange ? .updated : .unchanged
        )
    }

    /// One row per track globally. Active OTP wins legacy location conflicts;
    /// explicit local OTP suppression wins over stale remote membership.
    @discardableResult
    static func mergeDuplicateItems(in context: ModelContext, save: Bool = true) throws -> Int {
        let playlists = try PlaylistRepository.allPlaylists(in: context)
        let otpIDs = Set(playlists.filter { $0.role == .oneTruePlaylist && $0.isActive }.map(\.id))
        let groupedItems = Dictionary(grouping: try allItems(in: context).filter { !$0.isDeleted }, by: \.trackID)
        var mergedCount = 0

        for items in groupedItems.values where items.count > 1 {
            let orderedItems = items.sorted {
                if $0.locationChangedAt != $1.locationChangedAt {
                    return ($0.locationChangedAt ?? .distantPast) > ($1.locationChangedAt ?? .distantPast)
                }
                let leftSuppressed = $0.ownershipVersion > 0 && !$0.suppressedOTPMusicPlaylistIDs.isEmpty
                let rightSuppressed = $1.ownershipVersion > 0 && !$1.suppressedOTPMusicPlaylistIDs.isEmpty
                if leftSuppressed != rightSuppressed {
                    return leftSuppressed
                }
                let leftOTP = otpIDs.contains($0.playlistID) && $0.evictedAt == nil
                let rightOTP = otpIDs.contains($1.playlistID) && $1.evictedAt == nil
                if leftOTP != rightOTP { return leftOTP }
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            let keeper = orderedItems[0]
            let duplicates = orderedItems.dropFirst()

            let latestUpdatedItem = orderedItems.filter { $0.playlistID == keeper.playlistID }
                .max { $0.updatedAt < $1.updatedAt }
            if keeper.locationChangedAt == nil, let latestUpdatedItem, latestUpdatedItem !== keeper {
                adoptEvictionState(from: latestUpdatedItem, into: keeper)
            }

            for duplicate in duplicates {
                mergeStats(from: duplicate, into: keeper, adoptEvictionStateIfNewer: false)
                context.delete(duplicate)
                mergedCount += 1
            }
            if keeper.evictedAt == nil,
               let otp = playlists.first(where: { $0.id == keeper.playlistID && otpIDs.contains($0.id) }) {
                keeper.suppressedOTPMusicPlaylistIDs.removeAll { $0 == otp.musicPlaylistID }
            }
        }

        if mergedCount > 0, save {
            try context.save()
        }
        return mergedCount
    }

    /// Explicit movement keeps the supplied live identity and absorbs donors.
    @discardableResult
    static func mergeOtherItems(into keeper: PlaylistItemRecord, in context: ModelContext) throws -> Int {
        let duplicates = try allItems(in: context).filter { !$0.isDeleted && $0.trackID == keeper.trackID && $0.id != keeper.id }
        for duplicate in duplicates {
            mergeStats(from: duplicate, into: keeper, adoptEvictionStateIfNewer: false)
            context.delete(duplicate)
        }
        return duplicates.count
    }

    /// Folds one item's accumulated history into another. Counts are summed
    /// and dates take the later value, so a track that Overplay saw in two
    /// places keeps the whole picture rather than the half that happened to
    /// win.
    ///
    /// `adoptEvictionStateIfNewer` exists because the two callers resolve
    /// eviction differently: `mergeDuplicateItems` settles it once across a
    /// whole group before folding, while a pairwise merge has to decide as it
    /// goes. Recency wins either way — the most recent decision is the user's
    /// current intent, and letting eviction always win would hide tracks that
    /// still sit in an active playlist.
    static func mergeStats(
        from duplicate: PlaylistItemRecord,
        into keeper: PlaylistItemRecord,
        adoptEvictionStateIfNewer: Bool
    ) {
        if adoptEvictionStateIfNewer {
            let donorWins = if keeper.locationChangedAt != nil || duplicate.locationChangedAt != nil {
                (duplicate.locationChangedAt ?? .distantPast) > (keeper.locationChangedAt ?? .distantPast)
            } else {
                duplicate.updatedAt > keeper.updatedAt
            }
            if donorWins { adoptEvictionState(from: duplicate, into: keeper) }
        }

        keeper.entryProvenance = PlaylistEntryProvenance.merging(keeper.entryProvenance + duplicate.entryProvenance)
        keeper.skipCount += duplicate.skipCount
        keeper.playthroughCount += duplicate.playthroughCount
        keeper.isExplicitlyKept = keeper.isExplicitlyKept || duplicate.isExplicitlyKept
        keeper.hasRecordedActivity = keeper.hasListeningHistory || duplicate.hasListeningHistory
        // A merge with a new row must never make that row eligible for legacy cleanup.
        keeper.ownershipVersion = max(keeper.ownershipVersion, duplicate.ownershipVersion)
        for playlistID in duplicate.suppressedOTPMusicPlaylistIDs
        where !keeper.suppressedOTPMusicPlaylistIDs.contains(playlistID) {
            keeper.suppressedOTPMusicPlaylistIDs.append(playlistID)
        }
        keeper.lastPlayedAt = latestDate(keeper.lastPlayedAt, duplicate.lastPlayedAt)
        keeper.lastSkippedAt = latestDate(keeper.lastSkippedAt, duplicate.lastSkippedAt)
        keeper.lastSeenInPlaylistAt = latestDate(keeper.lastSeenInPlaylistAt, duplicate.lastSeenInPlaylistAt)
        if keeper.playlistID == duplicate.playlistID, keeper.musicPlaylistEntryID == nil {
            keeper.musicPlaylistEntryID = duplicate.musicPlaylistEntryID
        }
        for sourceMusicPlaylistID in duplicate.sourceMusicPlaylistIDs {
            keeper.addSourceMusicPlaylistID(sourceMusicPlaylistID)
        }
        keeper.updatedAt = max(keeper.updatedAt, duplicate.updatedAt)
    }

    private static func adoptEvictionState(
        from donor: PlaylistItemRecord,
        into keeper: PlaylistItemRecord
    ) {
        keeper.evictedAt = donor.evictedAt
        keeper.locationChangedAt = donor.locationChangedAt
        keeper.evictionReason = donor.evictionReason
        keeper.evictionSource = donor.evictionSource
    }

    private static func latestDate(_ left: Date?, _ right: Date?) -> Date? {
        switch (left, right) {
        case let (left?, right?):
            max(left, right)
        default:
            left ?? right
        }
    }
}
