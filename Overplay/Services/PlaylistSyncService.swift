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

struct PlaylistSyncSummary: Equatable {
    var fetchedCount = 0
    var insertedCount = 0
    var updatedCount = 0
    var unchangedCount = 0
    var skippedCount = 0
    var skippedReason: String?
    var artworkWarmupSnapshots: [TrackSnapshot] = []
}

@MainActor
struct PlaylistSyncService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "PlaylistSync"
    )
    private let playlistFetcher: any MusicLibraryPlaylistFetching

    init(playlistFetcher: any MusicLibraryPlaylistFetching = MusicKitLibraryPlaylistFetcher()) {
        self.playlistFetcher = playlistFetcher
    }

    func fetchLibraryPlaylists() async throws -> [AppleMusicPlaylist] {
        AppleMusicPlaylistDisplayOrder.sorted(try await fetchAllLibraryPlaylists()
            .map { playlist in
                AppleMusicPlaylist(
                    id: playlist.id.rawValue,
                    name: playlist.name,
                    trackCount: playlist.tracks?.count
                )
            })
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

        let summary = try reconcile(
            snapshots: snapshots,
            playlistRecord: playlistRecord,
            syncedAt: .now,
            in: context
        )
        try context.save()
        logSyncSummary(summary, playlistRecord: playlistRecord)
        warmUpArtworkThemes(for: summary.artworkWarmupSnapshots)
        return summary.fetchedCount
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
        let snapshots = sourceTracks.map { snapshot(from: $0, playlistID: record.musicPlaylistID) }
        let summary = try reconcile(
            snapshots: snapshots,
            playlistRecord: record,
            syncedAt: .now,
            in: context
        )
        try context.save()
        logSyncSummary(summary, playlistRecord: record)
        warmUpArtworkThemes(for: summary.artworkWarmupSnapshots)
        return record
    }

    @discardableResult
    func reconcile(
        snapshots: [TrackSnapshot],
        playlistRecord: PlaylistRecord,
        syncedAt: Date,
        in context: ModelContext
    ) throws -> PlaylistSyncSummary {
        var summary = PlaylistSyncSummary(fetchedCount: snapshots.count)

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
                let trackResult = try TrackRecordRepository.upsertWithResult(snapshot, in: context)
                let itemResult = try PlaylistItemRepository.upsertWithResult(
                    playlistID: playlistRecord.id,
                    trackID: trackResult.record.id,
                    musicPlaylistEntryID: snapshot.playlistEntryID,
                    sortOrder: sortOrder,
                    in: context
                )

                if itemResult.mutation.didChange {
                    itemResult.record.lastSeenInPlaylistAt = syncedAt
                }

                let mutation = combinedMutation(
                    trackMutation: trackResult.mutation,
                    itemMutation: itemResult.mutation
                )
                record(mutation, in: &summary)
                if mutation == .inserted || trackResult.shouldWarmUpArtworkTheme {
                    summary.artworkWarmupSnapshots.append(snapshot)
                }

                logLocalReconcileSucceeded(
                    snapshot,
                    playlistRecord: playlistRecord,
                    track: trackResult.record,
                    item: itemResult.record,
                    mutation: mutation
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
        return summary
    }

    private func logFoundRemoteTrack(
        _ snapshot: TrackSnapshot,
        playlistRecord: PlaylistRecord,
        sortOrder: Int,
        existingTrack: TrackRecord?,
        existingItem: PlaylistItemRecord?
    ) {
        Self.logger.debug(
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

    private func logLocalReconcileSucceeded(
        _ snapshot: TrackSnapshot,
        playlistRecord: PlaylistRecord,
        track: TrackRecord,
        item: PlaylistItemRecord,
        mutation: PersistenceMutation
    ) {
        Self.logger.debug(
            """
            Local sync \(mutation.logName, privacy: .public) playlist item for '\(snapshot.title, privacy: .public)' \
            in '\(playlistRecord.name, privacy: .public)' \
            localTrackID=\(track.id.uuidString, privacy: .public) \
            localPlaylistItemID=\(item.id.uuidString, privacy: .public) \
            sortOrder=\(item.sortOrder, privacy: .public) \
            evictedAt=\(item.evictedAt?.description ?? "nil", privacy: .public)
            """
        )
    }

    private func logSyncSummary(_ summary: PlaylistSyncSummary, playlistRecord: PlaylistRecord) {
        if let skippedReason = summary.skippedReason {
            Self.logger.info(
                """
                Skipped playlist sync for '\(playlistRecord.name, privacy: .public)' \
                reason=\(skippedReason, privacy: .public) \
                fetched=\(summary.fetchedCount, privacy: .public) \
                inserted=\(summary.insertedCount, privacy: .public) \
                updated=\(summary.updatedCount, privacy: .public) \
                unchanged=\(summary.unchangedCount, privacy: .public) \
                skipped=\(summary.skippedCount, privacy: .public)
                """
            )
        } else {
            Self.logger.info(
                """
                Synced playlist '\(playlistRecord.name, privacy: .public)' \
                fetched=\(summary.fetchedCount, privacy: .public) \
                inserted=\(summary.insertedCount, privacy: .public) \
                updated=\(summary.updatedCount, privacy: .public) \
                unchanged=\(summary.unchangedCount, privacy: .public) \
                skipped=\(summary.skippedCount, privacy: .public)
                """
            )
        }
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

    private func combinedMutation(
        trackMutation: PersistenceMutation,
        itemMutation: PersistenceMutation
    ) -> PersistenceMutation {
        if trackMutation == .inserted || itemMutation == .inserted {
            .inserted
        } else if trackMutation == .updated || itemMutation == .updated {
            .updated
        } else {
            .unchanged
        }
    }

    private func record(_ mutation: PersistenceMutation, in summary: inout PlaylistSyncSummary) {
        switch mutation {
        case .inserted:
            summary.insertedCount += 1
        case .updated:
            summary.updatedCount += 1
        case .unchanged:
            summary.unchangedCount += 1
        }
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
        try await playlistFetcher.fetchAllPlaylists(pageLimit: 100)
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

        PlaybackModeStore.rekeyMusicPlaylistID(from: oldID, to: newID, flushImmediately: true)
        LocalPlaybackStateStore.rekeyMusicPlaylistID(from: oldID, to: newID, flushImmediately: true)
        PlaybackIdentityStore.rekeyMusicPlaylistID(from: oldID, to: newID, flushImmediately: true)
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

    private func warmUpArtworkThemes(for snapshots: [TrackSnapshot]) {
        let tracks = snapshots.map(AlbumArtworkThemeWarmupTrack.init(snapshot:))
        Task(priority: .background) {
            await AlbumArtworkThemeWarmupService.shared.enqueue(tracks)
        }
    }
}
