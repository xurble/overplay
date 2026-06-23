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
            item.protected = false
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

    @discardableResult
    static func removeDuplicateItems(in context: ModelContext) throws -> Int {
        let groupedItems = Dictionary(grouping: try allItems(in: context)) { item in
            "\(item.playlistID.uuidString)::\(item.trackID.uuidString)"
        }
        var removedCount = 0

        for items in groupedItems.values where items.count > 1 {
            let orderedItems = items.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }

            for duplicate in orderedItems.dropFirst() {
                context.delete(duplicate)
                removedCount += 1
            }
        }

        if removedCount > 0 {
            try context.save()
        }
        return removedCount
    }
}
