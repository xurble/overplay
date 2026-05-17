import Foundation
import SwiftData

enum PlaylistItemRepository {
    static func allItems(in context: ModelContext) throws -> [PlaylistItemRecord] {
        let descriptor = FetchDescriptor<PlaylistItemRecord>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor)
    }

    static func item(id: UUID, in context: ModelContext) throws -> PlaylistItemRecord? {
        try allItems(in: context).first { $0.id == id }
    }

    static func item(playlistID: UUID, trackID: UUID, in context: ModelContext) throws -> PlaylistItemRecord? {
        try allItems(in: context).first { $0.playlistID == playlistID && $0.trackID == trackID }
    }

    static func items(forPlaylistID playlistID: UUID, in context: ModelContext) throws -> [PlaylistItemRecord] {
        try allItems(in: context).filter { $0.playlistID == playlistID }
    }

    static func playableItems(forPlaylistID playlistID: UUID, in context: ModelContext) throws -> [PlaylistItemRecord] {
        try items(forPlaylistID: playlistID, in: context).filter(\.isPlayable)
    }

    @discardableResult
    static func upsert(
        playlistID: UUID,
        trackID: UUID,
        musicPlaylistEntryID: String? = nil,
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
        item.updatedAt = .now
        return item
    }
}
