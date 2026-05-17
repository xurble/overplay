import Foundation
import SwiftData

enum PlaylistRepository {
    static func allPlaylists(in context: ModelContext) throws -> [PlaylistRecord] {
        let descriptor = FetchDescriptor<PlaylistRecord>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor)
    }

    static func activePlaylists(in context: ModelContext) throws -> [PlaylistRecord] {
        try allPlaylists(in: context).filter(\.isActive)
    }

    static func playlist(id: UUID, in context: ModelContext) throws -> PlaylistRecord? {
        try allPlaylists(in: context).first { $0.id == id }
    }

    static func playlist(musicPlaylistID: String, in context: ModelContext) throws -> PlaylistRecord? {
        try allPlaylists(in: context).first { $0.musicPlaylistID == musicPlaylistID }
    }

    static func oneTruePlaylist(in context: ModelContext) throws -> PlaylistRecord? {
        try activePlaylists(in: context).first { $0.role == .oneTruePlaylist }
    }

    @discardableResult
    static func upsert(
        musicPlaylistID: String,
        name: String,
        role: PlaylistRole,
        isActive: Bool = true,
        sortOrder: Int = 0,
        in context: ModelContext
    ) throws -> PlaylistRecord {
        let playlist = try playlist(musicPlaylistID: musicPlaylistID, in: context) ?? PlaylistRecord(
            musicPlaylistID: musicPlaylistID,
            name: name,
            role: role
        )

        if playlist.modelContext == nil {
            context.insert(playlist)
        }

        playlist.name = name
        playlist.role = role
        playlist.isActive = isActive
        playlist.sortOrder = sortOrder
        playlist.updatedAt = .now
        return playlist
    }
}
