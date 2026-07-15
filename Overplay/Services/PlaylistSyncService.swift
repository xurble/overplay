import Foundation
import OSLog
@preconcurrency import MusicKit
import SwiftData

enum PlaylistSyncError: LocalizedError {
    case playlistNotFound
    case playlistHasNoTracks
    case trackNotFoundInPlaylist
    case unsupportedSourceForOneTruePlaylist

    var errorDescription: String? {
        switch self {
        case .playlistNotFound:
            "The selected playlist could not be found."
        case .playlistHasNoTracks:
            "The selected playlist did not return any playable tracks."
        case .trackNotFoundInPlaylist:
            "The evicted track was not found in the selected Apple Music playlist."
        case .unsupportedSourceForOneTruePlaylist:
            "Only Apple Music playlists can be used as the One True Playlist."
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
    var insertedLocalTrackIDs: [String] = []
    var artworkWarmupSnapshots: [TrackSnapshot] = []

    /// Whether this sync changed durable records, and therefore whether a
    /// track identity merge pass could have anything to do.
    var didMutateRecords: Bool {
        insertedCount > 0 || updatedCount > 0
    }
}

@MainActor
struct PlaylistSyncService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "PlaylistSync"
    )

    private let sourceRegistry: PlaylistSourceSyncRegistry
    private let appleMusicSource: AppleMusicPlaylistSourceSync

    init(
        sourceRegistry: PlaylistSourceSyncRegistry = PlaylistSourceSyncRegistry(),
        appleMusicSource: AppleMusicPlaylistSourceSync = AppleMusicPlaylistSourceSync()
    ) {
        self.sourceRegistry = sourceRegistry
        self.appleMusicSource = appleMusicSource
    }

    func fetchLibraryPlaylists(source: PlaylistSource, in context: ModelContext) async throws -> [RemotePlaylistLink] {
        try await sourceRegistry.adapter(for: source).fetchLibraryPlaylists(in: context)
    }

    func fetchLibraryPlaylists() async throws -> [AppleMusicPlaylist] {
        try await fetchAppleMusicLibraryPlaylists()
    }

    func fetchAppleMusicLibraryPlaylists(in context: ModelContext? = nil) async throws -> [AppleMusicPlaylist] {
        let links: [RemotePlaylistLink]
        if let context {
            links = try await appleMusicSource.fetchLibraryPlaylists(in: context)
        } else {
            links = try await appleMusicSource.fetchLibraryPlaylists(in: .ephemeral)
        }
        return links.map {
            AppleMusicPlaylist(id: $0.id, name: $0.name, trackCount: $0.trackCount)
        }
    }

    func syncPlaylist(id playlistID: String, source: PlaylistSource, in context: ModelContext) async throws -> Int {
        let existingRecord = try PlaylistRepository.playlist(remotePlaylistID: playlistID, source: source, in: context)
        let record = try PlaylistRepository.upsert(
            remotePlaylist: RemotePlaylistLink(
                id: playlistID,
                name: existingRecord?.name ?? "Playlist",
                trackCount: nil,
                source: source
            ),
            role: existingRecord?.role ?? .oneTruePlaylist,
            in: context
        )
        return try await syncPlaylist(record, in: context).fetchedCount
    }

    @discardableResult
    func syncPlaylist(
        _ playlistRecord: PlaylistRecord,
        in context: ModelContext,
        runIdentityMerge: Bool = true
    ) async throws -> PlaylistSyncSummary {
        let adapter = sourceRegistry.adapter(for: playlistRecord)
        let fetchResult = try await adapter.fetchTrackSnapshots(
            playlistID: playlistRecord.musicPlaylistID,
            playlistName: playlistRecord.name,
            playlistRecord: playlistRecord,
            in: context
        )

        var summary = try await reconcile(
            snapshots: fetchResult.snapshots,
            playlistRecord: playlistRecord,
            syncedAt: .now,
            in: context
        )
        summary.skippedCount += fetchResult.skippedCount
        summary.skippedReason = fetchResult.skippedReason
        try context.save()
        if runIdentityMerge {
            try await TrackIdentityMergeService.mergeDuplicates(in: context)
        }
        logSyncSummary(summary, playlistRecord: playlistRecord)
        warmUpArtworkThemes(for: summary.artworkWarmupSnapshots)
        return summary
    }

    func syncAllLinkedPlaylists(in context: ModelContext) async throws -> Int {
        let playlists = try PlaylistRepository.activePlaylists(in: context)
        var syncedCount = 0
        var didMutateRecords = false

        for playlist in playlists {
            let summary = try await syncPlaylist(playlist, in: context, runIdentityMerge: false)
            syncedCount += summary.fetchedCount
            didMutateRecords = didMutateRecords || summary.didMutateRecords
        }

        if didMutateRecords {
            try await TrackIdentityMergeService.mergeDuplicates(in: context)
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
        CachingMusicLibraryPlaylistFetcher.shared.invalidate()
        let libraryPlaylists = try await fetchAppleMusicLibraryPlaylists()
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
        let summary = try await reconcile(
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

    /// How many per-track units of main-actor work run between yields in
    /// sync hot loops, keeping the UI responsive through catch-up syncs.
    static let syncYieldStride = 25

    @discardableResult
    func reconcile(
        snapshots: [TrackSnapshot],
        playlistRecord: PlaylistRecord,
        syncedAt: Date,
        in context: ModelContext
    ) async throws -> PlaylistSyncSummary {
        var summary = PlaylistSyncSummary(fetchedCount: snapshots.count)
        var seenRemoteTrackKeys = Set<String>()

        for (sortOrder, snapshot) in snapshots.enumerated() {
            if sortOrder > 0, sortOrder.isMultiple(of: Self.syncYieldStride) {
                await Task.yield()
            }
            let remoteTrackKey = snapshot.catalogID ?? snapshot.libraryID ?? snapshot.id
            guard seenRemoteTrackKeys.insert(remoteTrackKey).inserted else {
                summary.skippedCount += 1
                continue
            }

            let snapshotIdentity = snapshot.resolvedIdentity
            let existingTrack = try TrackRecordRepository.track(
                catalogID: snapshotIdentity.catalogID,
                libraryID: snapshotIdentity.libraryID,
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
                if mutation == .inserted {
                    summary.insertedLocalTrackIDs.append(trackResult.record.id.uuidString)
                }
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
        let items = try PlaylistItemRepository.items(forPlaylistID: playlistRecord.id, in: context)
        PlaybackOrderCoordinator.appendTrackIDs(
            summary.insertedLocalTrackIDs,
            playerID: "main",
            playlistID: playlistRecord.musicPlaylistID,
            orderTracks: PlaybackQueueBuilder.playbackOrderTracks(items: items)
        )
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
        try await appleMusicSource.loadPlaylist(
            id: playlistID,
            name: name,
            playlistRecord: playlistRecord,
            in: context
        )
    }

    private func loadTracks(for playlist: Playlist) async throws -> [Track] {
        let detailedPlaylist = try await playlist.with(.tracks)
        return Array(detailedPlaylist.tracks ?? [])
    }

    private func snapshot(from track: Track, playlistID: String) -> TrackSnapshot {
        let identity = MusicTrackIdentity.ids(for: track)
        return TrackSnapshot(
            id: track.id.rawValue,
            catalogID: identity.catalogID,
            libraryID: identity.libraryID,
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

private extension ModelContext {
    static var ephemeral: ModelContext {
        let schema = Schema([PlaylistRecord.self])
        let container = try! ModelContainer(for: schema, configurations: [
            ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        return ModelContext(container)
    }
}
