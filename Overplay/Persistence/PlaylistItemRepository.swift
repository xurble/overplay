import Foundation
import SwiftData

enum PlaylistItemRepository {
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

    static func resetAllStats(in context: ModelContext) throws {
        let items = try allItems(in: context)
        for item in items {
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
        guard let item = try item(playlistID: playlistID, trackID: trackID, in: context) else {
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
        if item.musicPlaylistEntryID != musicPlaylistEntryID {
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

    /// Collapses items that share a `(playlistID, trackID)` pair into the
    /// oldest item, merging stats instead of discarding them: skip and
    /// playthrough counts are summed, and eviction/protection state follows
    /// the most recently updated duplicate.
    @discardableResult
    static func mergeDuplicateItems(in context: ModelContext, save: Bool = true) throws -> Int {
        let groupedItems = Dictionary(grouping: try allItems(in: context)) { item in
            "\(item.playlistID.uuidString)::\(item.trackID.uuidString)"
        }
        var mergedCount = 0

        for items in groupedItems.values where items.count > 1 {
            let orderedItems = items.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            let keeper = orderedItems[0]
            let duplicates = orderedItems.dropFirst()

            let latestUpdatedItem = orderedItems.max { $0.updatedAt < $1.updatedAt }
            if let latestUpdatedItem, latestUpdatedItem !== keeper {
                adoptEvictionState(from: latestUpdatedItem, into: keeper)
            }

            for duplicate in duplicates {
                mergeStats(from: duplicate, into: keeper, adoptEvictionStateIfNewer: false)
                context.delete(duplicate)
                mergedCount += 1
            }
        }

        if mergedCount > 0, save {
            try context.save()
        }
        return mergedCount
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
        if adoptEvictionStateIfNewer, duplicate.updatedAt > keeper.updatedAt {
            adoptEvictionState(from: duplicate, into: keeper)
        }

        keeper.skipCount += duplicate.skipCount
        keeper.playthroughCount += duplicate.playthroughCount
        keeper.lastPlayedAt = latestDate(keeper.lastPlayedAt, duplicate.lastPlayedAt)
        keeper.lastSkippedAt = latestDate(keeper.lastSkippedAt, duplicate.lastSkippedAt)
        keeper.lastSeenInPlaylistAt = latestDate(keeper.lastSeenInPlaylistAt, duplicate.lastSeenInPlaylistAt)
        if keeper.musicPlaylistEntryID == nil {
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
