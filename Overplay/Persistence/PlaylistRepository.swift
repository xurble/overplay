import Foundation
import SwiftData

enum PlaylistRepository {
    struct TriageBucketConvergenceResult {
        var bucket: PlaylistRecord
        var createdBucket = false
        var normalizedBucketCount = 0
        var movedItemCount = 0
        var mergedItemCount = 0
        var reparentedHistoryEventCount = 0

        var didChangeAnything: Bool {
            createdBucket || normalizedBucketCount > 0 || movedItemCount > 0
                || mergedItemCount > 0 || reparentedHistoryEventCount > 0
        }
    }

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
        descriptor.includePendingChanges = true
        let playlists = try context.fetch(descriptor)
        return playlists.first(where: \.isActive) ?? playlists.first
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
    /// also creates it on demand so item-writing callers can rely on it. If
    /// CloudKit delivers buckets created independently by multiple devices,
    /// this converges them onto the same deterministic keeper before writing.
    @discardableResult
    static func triageBucket(in context: ModelContext) throws -> PlaylistRecord {
        try convergeTriageBuckets(in: context).bucket
    }

    /// Duplicate bucket records are retained as inactive aliases. CloudKit
    /// can deliver a record's rows after its parent, so keeping the UUID
    /// mapping lets every later pass absorb late items and history safely.
    static func convergeTriageBuckets(
        in context: ModelContext
    ) throws -> TriageBucketConvergenceResult {
        let buckets = try triageBuckets(in: context)
        if let keeper = buckets.first {
            var result = TriageBucketConvergenceResult(bucket: keeper)
            if !keeper.isActive {
                keeper.isActive = true
                keeper.updatedAt = .now
                result.normalizedBucketCount += 1
            }

            for duplicate in buckets.dropFirst() {
                let itemSummary = try PlaylistItemRepository.reparentItems(
                    from: duplicate.id,
                    to: keeper.id,
                    in: context
                )
                result.movedItemCount += itemSummary.movedCount
                result.mergedItemCount += itemSummary.mergedCount
                result.reparentedHistoryEventCount += try EventRepository.reparentEvents(
                    from: duplicate.id,
                    to: keeper.id,
                    in: context
                )
                if duplicate.isActive {
                    duplicate.isActive = false
                    duplicate.updatedAt = .now
                    result.normalizedBucketCount += 1
                }
            }
            return result
        }

        let bucket = PlaylistRecord(
            musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
            name: PlaylistRecord.triageBucketName,
            role: .triageBucket,
            writePolicy: .incomingOnly,
            sortOrder: 1
        )
        context.insert(bucket)
        return TriageBucketConvergenceResult(bucket: bucket, createdBucket: true)
    }

    /// Looks the bucket up without creating it, for read-only callers that
    /// must not write to the store just to render an empty state.
    static func existingTriageBucket(in context: ModelContext) throws -> PlaylistRecord? {
        let buckets = try triageBuckets(in: context)
        return buckets.first(where: \.isActive) ?? buckets.first
    }

    /// Resolves a bucket record retained by navigation or another UI surface
    /// after CloudKit convergence changed which UUID owns the shared bucket.
    /// Non-bucket playlists retain their own identity.
    static func canonicalPlaylist(
        for playlist: PlaylistRecord,
        among playlists: [PlaylistRecord]
    ) -> PlaylistRecord {
        guard playlist.role == .triageBucket else { return playlist }
        let buckets = orderedTriageBuckets(playlists)
        return buckets.first(where: \.isActive) ?? buckets.first ?? playlist
    }

    static func canonicalPlaylist(
        for playlist: PlaylistRecord,
        in context: ModelContext
    ) throws -> PlaylistRecord {
        canonicalPlaylist(for: playlist, among: try triageBuckets(in: context))
    }

    /// Sorts in memory for the UUID tie-break because CloudKit can preserve
    /// equal creation dates from independently created records. Every device
    /// must choose the same keeper once it sees the same set of buckets.
    private static func triageBuckets(in context: ModelContext) throws -> [PlaylistRecord] {
        let triageBucketRole = PlaylistRole.triageBucket.rawValue
        var descriptor = FetchDescriptor<PlaylistRecord>(
            predicate: #Predicate { $0.roleRawValue == triageBucketRole },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.includePendingChanges = true
        return orderedTriageBuckets(try context.fetch(descriptor))
    }

    private static func orderedTriageBuckets(
        _ playlists: [PlaylistRecord]
    ) -> [PlaylistRecord] {
        playlists.filter(\.isTriageBucket).sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
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
                existingPlaylist.triageLinkedAt = .now
                existingPlaylist.triageExcludedTrackIDs = []
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

        let source = try upsert(
            remotePlaylist: remotePlaylist,
            role: .triageSource,
            writePolicy: .managed,
            in: context
        )
        source.triageLinkedAt = .now
        try context.save()
        return source
    }

    @discardableResult
    static func addTriageSource(_ appleMusicPlaylist: AppleMusicPlaylist, in context: ModelContext) throws -> PlaylistRecord {
        try addTriageSource(RemotePlaylistLink(appleMusicPlaylist), in: context)
    }

    /// Detach provenance everywhere, including travelling OTP rows. Only
    /// unowned bucket rows are eligible for retention cleanup.
    static func removeTriageSource(
        _ playlist: PlaylistRecord,
        protectingItemID: UUID? = nil,
        in context: ModelContext
    ) throws {
        guard playlist.role == .triageSource else { return }

        let musicPlaylistID = playlist.musicPlaylistID
        playlist.isActive = false
        playlist.triageExcludedTrackIDs = []
        playlist.updatedAt = .now

        for item in try PlaylistItemRepository.allItems(in: context)
            where item.removeSourceMusicPlaylistID(musicPlaylistID) {
                item.updatedAt = .now
                try TrackRetentionPolicy.deleteIfUnowned(item, protectingItemID: protectingItemID, in: context)
        }

        try context.save()
    }
}
