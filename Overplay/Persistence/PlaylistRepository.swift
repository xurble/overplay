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

    static func playlist(
        remotePlaylistID: String,
        source: PlaylistSource,
        in context: ModelContext
    ) throws -> PlaylistRecord? {
        let sourceRawValue = source.rawValue
        var descriptor = FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate {
                $0.musicPlaylistID == remotePlaylistID && $0.sourceRawValue == sourceRawValue
            },
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
        remotePlaylist: RemotePlaylistLink,
        role: PlaylistRole,
        writePolicy: PlaylistWritePolicy = .managed,
        isActive: Bool = true,
        sortOrder: Int = 0,
        in context: ModelContext
    ) throws -> PlaylistRecord {
        if role == .oneTruePlaylist, remotePlaylist.source != .appleMusic {
            throw PlaylistSyncError.unsupportedSourceForOneTruePlaylist
        }

        let playlist = try playlist(
            remotePlaylistID: remotePlaylist.id,
            source: remotePlaylist.source,
            in: context
        ) ?? PlaylistRecord(
            musicPlaylistID: remotePlaylist.id,
            name: remotePlaylist.name,
            source: remotePlaylist.source,
            role: role
        )

        if playlist.modelContext == nil {
            context.insert(playlist)
        }

        playlist.name = remotePlaylist.name
        playlist.source = remotePlaylist.source
        playlist.role = role
        playlist.writePolicy = writePolicy
        playlist.isActive = isActive
        playlist.sortOrder = sortOrder
        playlist.updatedAt = .now
        return playlist
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
        try upsert(
            remotePlaylist: RemotePlaylistLink(
                id: musicPlaylistID,
                name: name,
                source: .appleMusic
            ),
            role: role,
            writePolicy: writePolicy,
            isActive: isActive,
            sortOrder: sortOrder,
            in: context
        )
    }

    @discardableResult
    static func setOneTruePlaylist(
        _ appleMusicPlaylist: AppleMusicPlaylist,
        writePolicy: PlaylistWritePolicy = .managed,
        in context: ModelContext
    ) throws -> PlaylistRecord {
        for existingPlaylist in try activePlaylists(in: context)
            where existingPlaylist.role == .oneTruePlaylist
            && existingPlaylist.musicPlaylistID != appleMusicPlaylist.id {
            existingPlaylist.role = .triage
            existingPlaylist.updatedAt = .now
        }

        return try upsert(
            remotePlaylist: RemotePlaylistLink(appleMusicPlaylist),
            role: .oneTruePlaylist,
            writePolicy: writePolicy,
            in: context
        )
    }

    @discardableResult
    static func addTriagePlaylist(_ remotePlaylist: RemotePlaylistLink, in context: ModelContext) throws -> PlaylistRecord {
        if remotePlaylist.source != .appleMusic,
           let existingPlaylist = try playlist(remotePlaylistID: remotePlaylist.id, source: remotePlaylist.source, in: context) {
            existingPlaylist.name = remotePlaylist.name
            existingPlaylist.isActive = true
            existingPlaylist.updatedAt = .now
            return existingPlaylist
        }

        if let existingPlaylist = try playlist(musicPlaylistID: remotePlaylist.id, in: context),
           existingPlaylist.role == .oneTruePlaylist {
            existingPlaylist.name = remotePlaylist.name
            existingPlaylist.isActive = true
            existingPlaylist.updatedAt = .now
            return existingPlaylist
        }

        return try upsert(
            remotePlaylist: remotePlaylist,
            role: .triage,
            writePolicy: remotePlaylist.source == .spotify ? .incomingOnly : .managed,
            in: context
        )
    }

    @discardableResult
    static func addTriagePlaylist(_ appleMusicPlaylist: AppleMusicPlaylist, in context: ModelContext) throws -> PlaylistRecord {
        try addTriagePlaylist(RemotePlaylistLink(appleMusicPlaylist), in: context)
    }

    static func deactivateTriagePlaylist(_ playlist: PlaylistRecord, in context: ModelContext) throws {
        guard playlist.role == .triage else { return }
        playlist.isActive = false
        playlist.updatedAt = .now
        try context.save()
    }
}
