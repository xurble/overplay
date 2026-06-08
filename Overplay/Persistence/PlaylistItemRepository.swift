import Foundation
import SwiftData

enum PlaylistItemRepository {
    static func allItems(in context: ModelContext) throws -> [PlaylistItemRecord] {
        let descriptor = FetchDescriptor<PlaylistItemRecord>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
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
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
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
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).first
    }

    static func items(forPlaylistID playlistID: UUID, in context: ModelContext) throws -> [PlaylistItemRecord] {
        var descriptor = FetchDescriptor<PlaylistItemRecord>(
            predicate: #Predicate { $0.playlistID == playlistID },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }

    static func playableItems(forPlaylistID playlistID: UUID, in context: ModelContext) throws -> [PlaylistItemRecord] {
        var descriptor = FetchDescriptor<PlaylistItemRecord>(
            predicate: #Predicate {
                $0.playlistID == playlistID && $0.evictedAt == nil
            },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
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
        let item = try item(playlistID: playlistID, trackID: trackID, in: context) ?? PlaylistItemRecord(
            playlistID: playlistID,
            trackID: trackID
        )

        if item.modelContext == nil {
            context.insert(item)
        }

        item.musicPlaylistEntryID = musicPlaylistEntryID
        if let sortOrder {
            item.sortOrder = sortOrder
        }
        item.updatedAt = .now
        return item
    }
}
