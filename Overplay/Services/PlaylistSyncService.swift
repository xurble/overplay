import Foundation
import OSLog
@preconcurrency import MusicKit
import SwiftData

enum PlaylistSyncError: LocalizedError {
    case playlistNotFound
    case playlistHasNoTracks
    case trackNotFoundInPlaylist

    var errorDescription: String? {
        switch self {
        case .playlistNotFound:
            "The selected Apple Music playlist could not be found."
        case .playlistHasNoTracks:
            "The selected playlist did not return any playable tracks."
        case .trackNotFoundInPlaylist:
            "The evicted track was not found in the selected Apple Music playlist."
        }
    }
}

@MainActor
struct PlaylistSyncService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "PlaylistSync"
    )

    func fetchLibraryPlaylists() async throws -> [AppleMusicPlaylist] {
        try await fetchAllLibraryPlaylists()
            .map { playlist in
                AppleMusicPlaylist(
                    id: playlist.id.rawValue,
                    name: playlist.name,
                    trackCount: playlist.tracks?.count
                )
            }
            .sorted { left, right in
                if left.isPreferredOverplayPlaylist != right.isPreferredOverplayPlaylist {
                    return left.isPreferredOverplayPlaylist
                }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    func syncPlaylist(id playlistID: String, in context: ModelContext) async throws -> Int {
        let existingRecord = try PlaylistRepository.playlist(musicPlaylistID: playlistID, in: context)
        let playlist = try await loadPlaylist(
            id: playlistID,
            name: existingRecord?.name,
            playlistRecord: existingRecord,
            in: context
        )
        let record = try PlaylistRepository.upsert(
            musicPlaylistID: playlist.id.rawValue,
            name: playlist.name,
            role: existingRecord?.role ?? .oneTruePlaylist,
            in: context
        )
        return try await syncPlaylist(record, in: context)
    }

    func syncPlaylist(_ playlistRecord: PlaylistRecord, in context: ModelContext) async throws -> Int {
        let playlist = try await loadPlaylist(
            id: playlistRecord.musicPlaylistID,
            name: playlistRecord.name,
            playlistRecord: playlistRecord,
            in: context
        )
        let tracks = try await loadTracks(for: playlist)
        let snapshots = tracks.map { snapshot(from: $0, playlistID: playlistRecord.musicPlaylistID) }
        Self.logger.info(
            "Fetched \(tracks.count, privacy: .public) remote tracks for playlist '\(playlistRecord.name, privacy: .public)' (\(playlistRecord.musicPlaylistID, privacy: .public))"
        )

        try reconcile(
            snapshots: snapshots,
            playlistRecord: playlistRecord,
            syncedAt: .now,
            in: context
        )
        try context.save()
        return tracks.count
    }

    func syncAllLinkedPlaylists(in context: ModelContext) async throws -> Int {
        let playlists = try PlaylistRepository.activePlaylists(in: context)
        var syncedCount = 0

        for playlist in playlists {
            syncedCount += try await syncPlaylist(playlist, in: context)
        }

        return syncedCount
    }

    @discardableResult
    func createManagedOneTruePlaylist(
        named name: String,
        copyingTracksFrom sourcePlaylistID: String? = nil,
        in context: ModelContext
    ) async throws -> PlaylistRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlistName = trimmedName.isEmpty ? "Overplay" : trimmedName
        let sourceTracks: [Track]

        if let sourcePlaylistID {
            let sourcePlaylist = try await loadPlaylist(id: sourcePlaylistID)
            sourceTracks = try await loadTracks(for: sourcePlaylist)
        } else {
            sourceTracks = []
        }

        let createdPlaylist = if sourceTracks.isEmpty {
            try await MusicLibrary.shared.createPlaylist(
                name: playlistName,
                description: "Managed by Overplay"
            )
        } else {
            try await MusicLibrary.shared.createPlaylist(
                name: playlistName,
                description: "Managed by Overplay",
                items: sourceTracks
            )
        }
        let libraryPlaylists = try await fetchLibraryPlaylists()
        let canonicalID = PlaylistLibraryIDResolver.resolvedMusicPlaylistID(
            storedID: createdPlaylist.id.rawValue,
            name: createdPlaylist.name,
            libraryPlaylists: libraryPlaylists.map { .init(id: $0.id, name: $0.name) }
        ) ?? createdPlaylist.id.rawValue

        if canonicalID != createdPlaylist.id.rawValue {
            Self.logger.warning(
                "createPlaylist returned \(createdPlaylist.id.rawValue, privacy: .public), but library reports \(canonicalID, privacy: .public) for '\(createdPlaylist.name, privacy: .public)'"
            )
        }

        let appleMusicPlaylist = AppleMusicPlaylist(
            id: canonicalID,
            name: createdPlaylist.name,
            trackCount: sourceTracks.count
        )
        let record = try PlaylistRepository.setOneTruePlaylist(
            appleMusicPlaylist,
            writePolicy: .managed,
            in: context
        )
        try reconcile(
            snapshots: sourceTracks.map { snapshot(from: $0, playlistID: record.musicPlaylistID) },
            playlistRecord: record,
            syncedAt: .now,
            in: context
        )
        try context.save()
        return record
    }

    @discardableResult
    func reconcile(
        snapshots: [TrackSnapshot],
        playlistRecord: PlaylistRecord,
        syncedAt: Date,
        in context: ModelContext
    ) throws -> Int {
        for (sortOrder, snapshot) in snapshots.enumerated() {
            let existingTrack = try TrackRecordRepository.track(
                catalogID: snapshot.catalogID ?? snapshot.id,
                libraryID: snapshot.libraryID ?? snapshot.id,
                in: context
            )
            let existingItem = try existingTrack.flatMap {
                try PlaylistItemRepository.item(
                    playlistID: playlistRecord.id,
                    trackID: $0.id,
                    in: context
                )
            }
            logFoundRemoteTrack(
                snapshot,
                playlistRecord: playlistRecord,
                sortOrder: sortOrder,
                existingTrack: existingTrack,
                existingItem: existingItem
            )

            do {
                let track = try TrackRecordRepository.upsert(snapshot, in: context)
                let item = try PlaylistItemRepository.upsert(
                    playlistID: playlistRecord.id,
                    trackID: track.id,
                    musicPlaylistEntryID: snapshot.playlistEntryID,
                    sortOrder: sortOrder,
                    in: context
                )
                item.lastSeenInPlaylistAt = syncedAt
                logLocalAddSucceeded(
                    snapshot,
                    playlistRecord: playlistRecord,
                    track: track,
                    item: item,
                    existedBeforeSync: existingItem != nil
                )
            } catch {
                logLocalAddFailed(
                    snapshot,
                    playlistRecord: playlistRecord,
                    error: error
                )
                throw error
            }
        }

        playlistRecord.lastSyncedAt = syncedAt
        playlistRecord.lastSyncError = nil
        playlistRecord.updatedAt = syncedAt
        return snapshots.count
    }

    private func logFoundRemoteTrack(
        _ snapshot: TrackSnapshot,
        playlistRecord: PlaylistRecord,
        sortOrder: Int,
        existingTrack: TrackRecord?,
        existingItem: PlaylistItemRecord?
    ) {
        Self.logger.info(
            """
            Found remote track \(sortOrder, privacy: .public) in '\(playlistRecord.name, privacy: .public)': \
            '\(snapshot.title, privacy: .public)' by '\(snapshot.artistName, privacy: .public)' \
            musicItemID=\(snapshot.id, privacy: .public) \
            catalogID=\(snapshot.catalogID ?? "nil", privacy: .public) \
            libraryID=\(snapshot.libraryID ?? "nil", privacy: .public) \
            localTrackExists=\(existingTrack != nil, privacy: .public) \
            localPlaylistItemExists=\(existingItem != nil, privacy: .public) \
            localItemPlayable=\(existingItem?.isPlayable.description ?? "nil", privacy: .public)
            """
        )
    }

    private func logLocalAddSucceeded(
        _ snapshot: TrackSnapshot,
        playlistRecord: PlaylistRecord,
        track: TrackRecord,
        item: PlaylistItemRecord,
        existedBeforeSync: Bool
    ) {
        let action = existedBeforeSync ? "updated" : "inserted"
        Self.logger.info(
            """
            Local sync \(action, privacy: .public) playlist item for '\(snapshot.title, privacy: .public)' \
            in '\(playlistRecord.name, privacy: .public)' \
            localTrackID=\(track.id.uuidString, privacy: .public) \
            localPlaylistItemID=\(item.id.uuidString, privacy: .public) \
            sortOrder=\(item.sortOrder, privacy: .public) \
            evictedAt=\(item.evictedAt?.description ?? "nil", privacy: .public)
            """
        )
    }

    private func logLocalAddFailed(
        _ snapshot: TrackSnapshot,
        playlistRecord: PlaylistRecord,
        error: Error
    ) {
        Self.logger.error(
            """
            Local sync failed for '\(snapshot.title, privacy: .public)' \
            in '\(playlistRecord.name, privacy: .public)' \
            musicItemID=\(snapshot.id, privacy: .public): \(error.localizedDescription, privacy: .public)
            """
        )
    }

    func playableMusicTracks(for playlistID: String, in context: ModelContext) async throws -> [Track] {
        if let playlistRecord = try PlaylistRepository.playlist(musicPlaylistID: playlistID, in: context) {
            return try await playableMusicTracks(for: playlistRecord, in: context)
        }

        let playlist = try await loadPlaylist(id: playlistID)
        return try await loadTracks(for: playlist)
    }

    func playableMusicTracks(for playlistRecord: PlaylistRecord, in context: ModelContext) async throws -> [Track] {
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistRecord.id, in: context)
        let localTracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        let tracksByID = localTracks.firstValueDictionary(keyedBy: \.id)
        let playableMusicItemIDs = PlaybackQueueBuilder.playableMusicItemIDs(
            items: items,
            tracksByID: tracksByID
        )

        guard !playableMusicItemIDs.isEmpty else {
            return []
        }

        let playlist = try await loadPlaylist(
            id: playlistRecord.musicPlaylistID,
            name: playlistRecord.name,
            playlistRecord: playlistRecord,
            in: context
        )
        let tracks = try await loadTracks(for: playlist)
        return tracks.filter { playableMusicItemIDs.contains($0.id.rawValue) }
    }

    func removeTrackFromPlaylist(trackID: String, playlistID: String) async throws {
        let playlist = try await loadPlaylist(id: playlistID)
        let tracks = try await loadTracks(for: playlist)
        let remainingTracks = tracks.filter { $0.id.rawValue != trackID }

        guard remainingTracks.count < tracks.count else {
            throw PlaylistSyncError.trackNotFoundInPlaylist
        }

        try await MusicLibrary.shared.edit(playlist, items: remainingTracks)
    }

    func loadPlaylist(
        id playlistID: String,
        name: String? = nil,
        playlistRecord: PlaylistRecord? = nil,
        in context: ModelContext? = nil
    ) async throws -> Playlist {
        let libraryPlaylists = try await fetchAllLibraryPlaylists()
        let candidates = libraryPlaylists.map {
            PlaylistLibraryIDResolver.Candidate(id: $0.id.rawValue, name: $0.name)
        }

        guard let resolvedID = PlaylistLibraryIDResolver.resolvedMusicPlaylistID(
            storedID: playlistID,
            name: name,
            libraryPlaylists: candidates
        ) else {
            throw PlaylistSyncError.playlistNotFound
        }

        if resolvedID != playlistID,
           let playlistRecord,
           let context {
            try applyHealedMusicPlaylistID(
                from: playlistID,
                to: resolvedID,
                playlistRecord: playlistRecord,
                in: context
            )
        }

        guard let playlist = libraryPlaylists.first(where: { $0.id.rawValue == resolvedID }) else {
            throw PlaylistSyncError.playlistNotFound
        }

        return playlist
    }

    private func fetchAllLibraryPlaylists() async throws -> [Playlist] {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = 100
        request.sort(by: \.name, ascending: true)
        return Array(try await request.response().items)
    }

    private func applyHealedMusicPlaylistID(
        from oldID: String,
        to newID: String,
        playlistRecord: PlaylistRecord,
        in context: ModelContext
    ) throws {
        Self.logger.warning(
            "Healed stale Apple Music playlist ID from \(oldID, privacy: .public) to \(newID, privacy: .public) for '\(playlistRecord.name, privacy: .public)'"
        )

        playlistRecord.musicPlaylistID = newID
        playlistRecord.updatedAt = .now

        let settings = try SettingsRepository.settings(in: context)
        if settings.selectedPlaylistID == oldID {
            settings.selectedPlaylistID = newID
            settings.updatedAt = .now
        }

        PlaybackModeStore.rekeyMusicPlaylistID(from: oldID, to: newID)
        LocalPlaybackStateStore.rekeyMusicPlaylistID(from: oldID, to: newID)
        try context.save()
    }

    private func loadTracks(for playlist: Playlist) async throws -> [Track] {
        let detailedPlaylist = try await playlist.with(.tracks)
        return Array(detailedPlaylist.tracks ?? [])
    }

    private func snapshot(from track: Track, playlistID: String) -> TrackSnapshot {
        TrackSnapshot(
            id: track.id.rawValue,
            catalogID: track.id.rawValue,
            libraryID: track.id.rawValue,
            playlistEntryID: nil,
            playlistID: playlistID,
            title: track.title,
            artistName: track.artistName,
            albumTitle: track.albumTitle,
            artworkURLTemplate: track.artwork?.url(width: 512, height: 512)?.absoluteString,
            durationSeconds: track.duration,
            musicKitPlaybackData: try? JSONEncoder().encode(track)
        )
    }
}
