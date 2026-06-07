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
        var descriptor = FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }

    static func playlist(id: UUID, in context: ModelContext) throws -> PlaylistRecord? {
        var descriptor = FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate { $0.id == id },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).first
    }

    static func playlist(musicPlaylistID: String, in context: ModelContext) throws -> PlaylistRecord? {
        var descriptor = FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate { $0.musicPlaylistID == musicPlaylistID },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).first
    }

    static func oneTruePlaylist(in context: ModelContext) throws -> PlaylistRecord? {
        let oneTruePlaylistRole = PlaylistRole.oneTruePlaylist.rawValue
        var descriptor = FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate {
                $0.isActive && $0.roleRawValue == oneTruePlaylistRole
            },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).first
    }

    @discardableResult
    static func upsert(
        musicPlaylistID: String,
        name: String,
        role: PlaylistRole,
        writePolicy: PlaylistWritePolicy = .managed,
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
        playlist.writePolicy = writePolicy
        playlist.isActive = isActive
        playlist.sortOrder = sortOrder
        playlist.updatedAt = .now
        return playlist
    }

    @discardableResult
    static func setOneTruePlaylist(
        _ appleMusicPlaylist: AppleMusicPlaylist,
        writePolicy: PlaylistWritePolicy = .managed,
        in context: ModelContext
    ) throws -> PlaylistRecord {
        for existingPlaylist in try activePlaylists(in: context) where existingPlaylist.role == .oneTruePlaylist && existingPlaylist.musicPlaylistID != appleMusicPlaylist.id {
            existingPlaylist.role = .triage
            existingPlaylist.updatedAt = .now
        }

        return try upsert(
            musicPlaylistID: appleMusicPlaylist.id,
            name: appleMusicPlaylist.name,
            role: .oneTruePlaylist,
            writePolicy: writePolicy,
            in: context
        )
    }

    @discardableResult
    static func addTriagePlaylist(_ appleMusicPlaylist: AppleMusicPlaylist, in context: ModelContext) throws -> PlaylistRecord {
        if let existingPlaylist = try playlist(musicPlaylistID: appleMusicPlaylist.id, in: context),
           existingPlaylist.role == .oneTruePlaylist {
            existingPlaylist.name = appleMusicPlaylist.name
            existingPlaylist.isActive = true
            existingPlaylist.updatedAt = .now
            return existingPlaylist
        }

        return try upsert(
            musicPlaylistID: appleMusicPlaylist.id,
            name: appleMusicPlaylist.name,
            role: .triage,
            writePolicy: .managed,
            in: context
        )
    }

    static func deactivateTriagePlaylist(_ playlist: PlaylistRecord, in context: ModelContext) throws {
        guard playlist.role == .triage else { return }
        playlist.isActive = false
        playlist.updatedAt = .now
        try context.save()
    }
}
