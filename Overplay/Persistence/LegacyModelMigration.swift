import Foundation
import SwiftData

enum LegacyModelMigration {
    @MainActor
    static func migrate(in context: ModelContext) throws {
        let settings = try existingSettings(in: context)
        let legacyTracks = try TrackRepository.allTracks(in: context)

        guard settings?.selectedPlaylistID != nil || !legacyTracks.isEmpty else {
            return
        }

        let selectedPlaylist = try settings.flatMap { try migrateSelectedPlaylist($0, in: context) }
        try migrateLegacyTracks(
            legacyTracks,
            fallbackPlaylist: selectedPlaylist,
            evictAfterSkips: settings?.evictAfterSkips ?? 3,
            in: context
        )
        try context.save()
    }

    @MainActor
    private static func existingSettings(in context: ModelContext) throws -> OverplaySettings? {
        var descriptor = FetchDescriptor<OverplaySettings>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @MainActor
    private static func migrateSelectedPlaylist(
        _ settings: OverplaySettings,
        in context: ModelContext
    ) throws -> PlaylistRecord? {
        guard let selectedPlaylistID = settings.selectedPlaylistID else {
            return nil
        }

        return try PlaylistRepository.upsert(
            musicPlaylistID: selectedPlaylistID,
            name: settings.selectedPlaylistName ?? "One True Playlist",
            role: .oneTruePlaylist,
            in: context
        )
    }

    @MainActor
    private static func migrateLegacyTracks(
        _ legacyTracks: [TrackedTrack],
        fallbackPlaylist: PlaylistRecord?,
        evictAfterSkips: Int,
        in context: ModelContext
    ) throws {
        for legacyTrack in legacyTracks {
            let playlist = try playlist(for: legacyTrack, fallbackPlaylist: fallbackPlaylist, in: context)
            let track = try TrackRecordRepository.upsert(legacyTrack, in: context)
            let item = try PlaylistItemRepository.upsert(
                playlistID: playlist.id,
                trackID: track.id,
                musicPlaylistEntryID: legacyTrack.playlistEntryID,
                in: context
            )

            item.skipCount = legacyTrack.skipCount
            item.playthroughCount = legacyTrack.playthroughCount
            item.lastPlayedAt = legacyTrack.lastPlayedAt
            item.lastSkippedAt = legacyTrack.lastSkippedAt
            item.lastSeenInPlaylistAt = legacyTrack.lastSeenInPlaylistAt
            item.evictedAt = legacyTrack.evictedAt
            item.protected = legacyTrack.protected
            item.createdAt = legacyTrack.createdAt
            item.updatedAt = legacyTrack.updatedAt

            if legacyTrack.evictedAt != nil {
                let eviction = evictionDetails(for: legacyTrack, evictAfterSkips: evictAfterSkips)
                item.evictionReason = eviction.reason
                item.evictionSource = eviction.source
            } else {
                item.evictionReason = nil
                item.evictionSource = nil
            }
        }
    }

    @MainActor
    private static func playlist(
        for legacyTrack: TrackedTrack,
        fallbackPlaylist: PlaylistRecord?,
        in context: ModelContext
    ) throws -> PlaylistRecord {
        if let playlistID = legacyTrack.playlistID {
            if let playlist = try PlaylistRepository.playlist(musicPlaylistID: playlistID, in: context) {
                return playlist
            }

            return try PlaylistRepository.upsert(
                musicPlaylistID: playlistID,
                name: fallbackPlaylist?.musicPlaylistID == playlistID ? fallbackPlaylist?.name ?? "One True Playlist" : "Imported Playlist",
                role: fallbackPlaylist?.musicPlaylistID == playlistID ? .oneTruePlaylist : .triage,
                in: context
            )
        }

        if let fallbackPlaylist {
            return fallbackPlaylist
        }

        return try PlaylistRepository.upsert(
            musicPlaylistID: "legacy-unassigned",
            name: "Legacy Unassigned",
            role: .triage,
            isActive: false,
            in: context
        )
    }

    private static func evictionDetails(
        for legacyTrack: TrackedTrack,
        evictAfterSkips: Int
    ) -> (reason: EvictionReason, source: EvictionSource) {
        guard let evictionReason = legacyTrack.evictionReason?.lowercased() else {
            return (.manual, .user)
        }

        if evictionReason.contains("skip") || legacyTrack.skipCount >= evictAfterSkips {
            return (.skipCount, .playbackRule)
        }

        return (.manual, .user)
    }
}
