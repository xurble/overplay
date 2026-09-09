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

    /// The single triage bucket. Startup ensures it exists, and this accessor
    /// also creates it on demand so item-writing callers can rely on it.
    @discardableResult
    static func triageBucket(in context: ModelContext) throws -> PlaylistRecord {
        if let existingBucket = try existingTriageBucket(in: context) {
            return existingBucket
        }

        let bucket = PlaylistRecord(
            musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
            name: PlaylistRecord.triageBucketName,
            role: .triageBucket,
            writePolicy: .incomingOnly,
            sortOrder: 1
        )
        context.insert(bucket)
        return bucket
    }

    /// Looks the bucket up without creating it, for read-only callers that
    /// must not write to the store just to render an empty state.
    static func existingTriageBucket(in context: ModelContext) throws -> PlaylistRecord? {
        let triageBucketRole = PlaylistRole.triageBucket.rawValue
        var descriptor = FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate { $0.roleRawValue == triageBucketRole },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).first
    }

    /// The contributing Apple Music playlists that feed the bucket.
    static func triageSources(in context: ModelContext) throws -> [PlaylistRecord] {
        let triageSourceRole = PlaylistRole.triageSource.rawValue
        var descriptor = FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate { $0.isActive && $0.roleRawValue == triageSourceRole },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
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
        let demotedPlaylists = try activePlaylists(in: context)
            .filter {
                $0.role == .oneTruePlaylist
                    && $0.musicPlaylistID != appleMusicPlaylist.id
            }

        if !demotedPlaylists.isEmpty {
            let bucket = try triageBucket(in: context)
            for existingPlaylist in demotedPlaylists {
                try PlaylistItemRepository.reparentItems(
                    from: existingPlaylist.id,
                    to: bucket.id,
                    sourceMusicPlaylistID: existingPlaylist.musicPlaylistID,
                    in: context
                )
            }
        }

        for existingPlaylist in demotedPlaylists {
            existingPlaylist.role = .triageSource
            existingPlaylist.updatedAt = .now
        }

        return try upsert(
            remotePlaylist: RemotePlaylistLink(appleMusicPlaylist),
            role: .oneTruePlaylist,
            writePolicy: writePolicy,
            in: context
        )
    }

    /// Links an Apple Music playlist as a contributor to the triage bucket.
    /// The One True Playlist is never converted into a contributor — it is
    /// already tracked, and demoting it here would silently move the user's
    /// main playlist.
    @discardableResult
    static func addTriageSource(_ remotePlaylist: RemotePlaylistLink, in context: ModelContext) throws -> PlaylistRecord {
        try triageBucket(in: context)

        if let existingPlaylist = try playlist(
            remotePlaylistID: remotePlaylist.id,
            source: remotePlaylist.source,
            in: context
        ) {
            let isRelinking = !existingPlaylist.isActive
            if existingPlaylist.role != .oneTruePlaylist {
                existingPlaylist.role = .triageSource
            }
            existingPlaylist.name = remotePlaylist.name
            existingPlaylist.isActive = true
            if isRelinking {
                // Unlinking deliberately removes this source's provenance
                // from retained bucket rows. Force the first sync after a
                // relink to fetch tracks even when Apple reports the remote
                // playlist unchanged, so attribution can be restored.
                existingPlaylist.lastSyncedAt = nil
                existingPlaylist.remoteLastModifiedAt = nil
                existingPlaylist.lastSyncError = nil
            }
            existingPlaylist.updatedAt = .now
            return existingPlaylist
        }

        return try upsert(
            remotePlaylist: remotePlaylist,
            role: .triageSource,
            writePolicy: .managed,
            in: context
        )
    }

    @discardableResult
    static func addTriageSource(_ appleMusicPlaylist: AppleMusicPlaylist, in context: ModelContext) throws -> PlaylistRecord {
        try addTriageSource(RemotePlaylistLink(appleMusicPlaylist), in: context)
    }

    /// Unlinks a contributing playlist. Its tracks stay in the bucket and
    /// keep their stats — they are simply left unattributed, because the row
    /// is the track's only row and deleting it would destroy history the
    /// user never asked to lose.
    static func removeTriageSource(_ playlist: PlaylistRecord, in context: ModelContext) throws {
        guard playlist.role == .triageSource else { return }

        let musicPlaylistID = playlist.musicPlaylistID
        playlist.isActive = false
        playlist.updatedAt = .now

        if let bucket = try existingTriageBucket(in: context) {
            for item in try PlaylistItemRepository.items(forPlaylistID: bucket.id, in: context)
            where item.removeSourceMusicPlaylistID(musicPlaylistID) {
                item.updatedAt = .now
            }
        }

        try context.save()
    }
}
