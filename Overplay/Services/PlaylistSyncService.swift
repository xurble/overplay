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
    private static let osLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "PlaylistSync"
    )

    /// `lastSeenInPlaylistAt` must track every sync sighting so future
    /// missing-from-remote logic has accurate data, but stamping a fresh
    /// date on every 30-minute cycle would dirty every item record and
    /// churn CloudKit. Day resolution is enough for any pruning decision,
    /// so an unchanged item is restamped only once its stamp is a day old.
    static let lastSeenRefreshInterval: TimeInterval = 24 * 60 * 60

    static func shouldRefreshLastSeen(current: Date?, syncedAt: Date, didChange: Bool) -> Bool {
        if didChange {
            return true
        }
        guard let current else {
            return true
        }
        return syncedAt.timeIntervalSince(current) >= lastSeenRefreshInterval
    }

    private let sourceRegistry: PlaylistSourceSyncRegistry
    private let appleMusicSource: AppleMusicPlaylistSourceSync
    private let yieldDuringReconciliation: @MainActor () async throws -> Void

    init(
        sourceRegistry: PlaylistSourceSyncRegistry = PlaylistSourceSyncRegistry(),
        appleMusicSource: AppleMusicPlaylistSourceSync = AppleMusicPlaylistSourceSync(),
        yieldDuringReconciliation: @escaping @MainActor () async throws -> Void = {
            await Task.yield()
        }
    ) {
        self.sourceRegistry = sourceRegistry
        self.appleMusicSource = appleMusicSource
        self.yieldDuringReconciliation = yieldDuringReconciliation
    }

    func fetchLibraryPlaylists(source: PlaylistSource) async throws -> [RemotePlaylistLink] {
        try await sourceRegistry.adapter(for: source).fetchLibraryPlaylists()
    }

    func fetchLibraryPlaylists() async throws -> [AppleMusicPlaylist] {
        try await fetchAppleMusicLibraryPlaylists()
    }

    func fetchAppleMusicLibraryPlaylists() async throws -> [AppleMusicPlaylist] {
        let links = try await appleMusicSource.fetchLibraryPlaylists()
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

    /// - Parameter skipWhenRemoteUnchanged: Let the source skip the track
    ///   fetch when it can prove the remote playlist has not changed. Only
    ///   automatic cycles pass true; a user-initiated sync always reads the
    ///   real remote state.
    @discardableResult
    func syncPlaylist(
        _ playlistRecord: PlaylistRecord,
        in context: ModelContext,
        runIdentityMerge: Bool = true,
        skipWhenRemoteUnchanged: Bool = false
    ) async throws -> PlaylistSyncSummary {
        guard playlistRecord.isActive else {
            return inactivePlaylistSummary()
        }

        // The bucket has no Apple Music playlist of its own, so syncing it
        // means syncing everything that feeds it. Handled here rather than in
        // each caller so the dashboard, the sources screen and CarPlay all
        // behave the same way.
        if playlistRecord.role == .triageBucket {
            return try await syncTriageSources(
                into: playlistRecord,
                in: context,
                runIdentityMerge: runIdentityMerge,
                skipWhenRemoteUnchanged: skipWhenRemoteUnchanged
            )
        }

        let adapter = sourceRegistry.adapter(for: playlistRecord)
        let fetchResult = try await adapter.fetchTrackSnapshots(
            playlistID: playlistRecord.musicPlaylistID,
            playlistName: playlistRecord.name,
            playlistRecord: playlistRecord,
            skipWhenRemoteUnchanged: skipWhenRemoteUnchanged,
            in: context
        )

        // The user can unlink a source while its remote fetch is suspended.
        // Re-check the durable record before applying any fetched tracks so
        // that an in-flight sync cannot restore the provenance unlink removed.
        guard playlistRecord.isActive else {
            return inactivePlaylistSummary(skippedCount: fetchResult.snapshots.count)
        }

        guard fetchResult.didFetchTracks else {
            // Nothing was fetched because nothing changed. Record the visit
            // so freshness gating still works, and leave the existing
            // tracks and local order untouched.
            var summary = PlaylistSyncSummary()
            summary.skippedCount = max(fetchResult.skippedCount, 1)
            summary.skippedReason = fetchResult.skippedReason ?? "remoteUnchanged"
            playlistRecord.lastSyncedAt = .now
            playlistRecord.lastSyncError = nil
            playlistRecord.updatedAt = .now
            try context.save()
            logSyncSummary(summary, playlistRecord: playlistRecord)
            return summary
        }

        var summary = try await reconcile(
            snapshots: fetchResult.snapshots,
            playlistRecord: playlistRecord,
            syncedAt: .now,
            in: context
        )
        summary.skippedCount += fetchResult.skippedCount
        summary.skippedReason = fetchResult.skippedReason
        playlistRecord.remoteLastModifiedAt = fetchResult.remoteLastModifiedAt
        try context.save()
        if runIdentityMerge {
            try await TrackIdentityMergeService.mergeDuplicates(in: context)
        }
        logSyncSummary(summary, playlistRecord: playlistRecord)
        warmUpArtworkThemes(for: summary.artworkWarmupSnapshots)
        return summary
    }

    /// Syncs every contributing playlist and reports the combined result, so
    /// a bucket sync reads as one action.
    private func syncTriageSources(
        into bucket: PlaylistRecord,
        in context: ModelContext,
        runIdentityMerge: Bool,
        skipWhenRemoteUnchanged: Bool
    ) async throws -> PlaylistSyncSummary {
        let sources = try PlaylistRepository.triageSources(in: context)

        guard !sources.isEmpty else {
            var summary = PlaylistSyncSummary()
            summary.skippedCount = 1
            summary.skippedReason = "noTriageSources"
            bucket.lastSyncedAt = .now
            bucket.lastSyncError = nil
            bucket.updatedAt = .now
            try context.save()
            return summary
        }

        var combinedSummary = PlaylistSyncSummary()
        var firstError: Error?

        for source in sources {
            do {
                // Each source reconciles into the bucket, so the identity
                // merge waits until every one has landed.
                let summary = try await syncPlaylist(
                    source,
                    in: context,
                    runIdentityMerge: false,
                    skipWhenRemoteUnchanged: skipWhenRemoteUnchanged
                )
                combinedSummary.fetchedCount += summary.fetchedCount
                combinedSummary.insertedCount += summary.insertedCount
                combinedSummary.updatedCount += summary.updatedCount
                combinedSummary.unchangedCount += summary.unchangedCount
                combinedSummary.skippedCount += summary.skippedCount
                combinedSummary.insertedLocalTrackIDs.append(contentsOf: summary.insertedLocalTrackIDs)
                combinedSummary.artworkWarmupSnapshots.append(contentsOf: summary.artworkWarmupSnapshots)
            } catch {
                // One unreachable contributor must not hide the tracks the
                // others delivered, so record it and carry on.
                source.lastSyncError = error.localizedDescription
                source.updatedAt = .now
                firstError = firstError ?? error
            }
        }

        try context.save()

        if runIdentityMerge, combinedSummary.didMutateRecords {
            try await TrackIdentityMergeService.mergeDuplicates(in: context)
        }

        if let firstError, combinedSummary.fetchedCount == 0 {
            throw firstError
        }

        return combinedSummary
    }

    func syncAllLinkedPlaylists(in context: ModelContext) async throws -> Int {
        // The triage bucket is active and linked but has no Apple Music
        // playlist to fetch — it is fed by its contributing sources.
        let playlists = try PlaylistRepository.activePlaylists(in: context)
            .filter(\.hasRemoteSource)
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

        let createdPlaylist = try await MusicKitActivityLog.shared.measure(
            .libraryPlaylistCreate,
            magnitude: Double(sourceTracks.count)
        ) {
            if sourceTracks.isEmpty {
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
        guard playlistRecord.isActive else {
            return inactivePlaylistSummary(skippedCount: snapshots.count)
        }

        var summary = PlaylistSyncSummary(fetchedCount: snapshots.count)
        var seenRemoteTrackKeys = Set<String>()
        // A contributing playlist keeps its own sync bookkeeping but does not
        // own items: everything it contributes lands in the shared bucket, so
        // the same track arriving from two playlists is one row.
        var currentItemOwner = try itemOwner(for: playlistRecord, in: context)
        var contributedSourceMusicPlaylistID = currentItemOwner === playlistRecord
            ? nil
            : playlistRecord.musicPlaylistID
        var itemOwnersByID = [currentItemOwner.id: currentItemOwner]
        var processedSnapshots: [TrackSnapshot] = []
        var insertedOrderTrackIDs = Set<String>()

        for (sortOrder, snapshot) in snapshots.enumerated() {
            if sortOrder > 0, sortOrder.isMultiple(of: Self.syncYieldStride) {
                try await yieldDuringReconciliation()
                guard playlistRecord.isActive else {
                    summary.fetchedCount = sortOrder
                    summary.skippedCount += snapshots.count - sortOrder
                    summary.skippedReason = "inactivePlaylist"
                    return summary
                }
                // Selection can promote or demote the playlist while this
                // main-actor sync yields. Re-resolve ownership and replay the
                // completed prefix into the new owner so one successful sync
                // never leaves its snapshots split across the old and new
                // destinations.
                let resolvedItemOwner = try itemOwner(for: playlistRecord, in: context)
                if resolvedItemOwner.id != currentItemOwner.id {
                    currentItemOwner = resolvedItemOwner
                    contributedSourceMusicPlaylistID = currentItemOwner === playlistRecord
                        ? nil
                        : playlistRecord.musicPlaylistID
                    itemOwnersByID[currentItemOwner.id] = currentItemOwner
                    let replayedTrackIDs = try replayProcessedSnapshots(
                        processedSnapshots,
                        itemOwner: currentItemOwner,
                        contributedSourceMusicPlaylistID: contributedSourceMusicPlaylistID,
                        syncedAt: syncedAt,
                        in: context
                    )
                    for localTrackID in replayedTrackIDs
                    where insertedOrderTrackIDs.insert(localTrackID).inserted {
                        summary.insertedLocalTrackIDs.append(localTrackID)
                    }
                }
            }
            let remoteTrackKey = snapshot.catalogID ?? snapshot.libraryID ?? snapshot.id
            guard seenRemoteTrackKeys.insert(remoteTrackKey).inserted else {
                summary.skippedCount += 1
                continue
            }

            // These lookups exist only to feed the debug log line — two
            // indexed fetches per track, ~1000 wasted fetches on a
            // 500-track playlist when debug logging is off.
            if Self.osLog.isEnabled(type: .debug) {
                let snapshotIdentity = snapshot.resolvedIdentity
                let existingTrack = try TrackRecordRepository.track(
                    catalogID: snapshotIdentity.catalogID,
                    libraryID: snapshotIdentity.libraryID,
                    in: context
                )
                let existingItem = try existingTrack.flatMap {
                    try PlaylistItemRepository.item(
                        playlistID: currentItemOwner.id,
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
            }

            do {
                let trackResult = try TrackRecordRepository.upsertWithResult(snapshot, in: context)
                let itemResult = try PlaylistItemRepository.upsertWithResult(
                    playlistID: currentItemOwner.id,
                    trackID: trackResult.record.id,
                    musicPlaylistEntryID: snapshot.playlistEntryID,
                    in: context
                )

                if let contributedSourceMusicPlaylistID,
                   itemResult.record.addSourceMusicPlaylistID(contributedSourceMusicPlaylistID) {
                    itemResult.record.updatedAt = syncedAt
                }

                if Self.shouldRefreshLastSeen(
                    current: itemResult.record.lastSeenInPlaylistAt,
                    syncedAt: syncedAt,
                    didChange: itemResult.mutation.didChange
                ) {
                    itemResult.record.lastSeenInPlaylistAt = syncedAt
                }

                let mutation = combinedMutation(
                    trackMutation: trackResult.mutation,
                    itemMutation: itemResult.mutation
                )
                record(mutation, in: &summary)
                let localTrackID = trackResult.record.id.uuidString
                if mutation == .inserted,
                   insertedOrderTrackIDs.insert(localTrackID).inserted {
                    summary.insertedLocalTrackIDs.append(localTrackID)
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
                processedSnapshots.append(snapshot)
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
        for owner in itemOwnersByID.values {
            if owner !== playlistRecord {
                owner.lastSyncedAt = syncedAt
                owner.updatedAt = syncedAt
            }
            let items = try PlaylistItemRepository.items(forPlaylistID: owner.id, in: context)
            PlaybackOrderCoordinator.appendTrackIDs(
                summary.insertedLocalTrackIDs,
                playerID: "main",
                playlistID: owner.musicPlaylistID,
                orderTracks: PlaybackQueueBuilder.playbackOrderTracks(items: items)
            )
        }
        return summary
    }

    /// Replays the already completed chunk into a newly selected owner after
    /// a role transition. Track upserts are idempotent; item upserts ensure a
    /// promoted playlist receives the whole remote snapshot while a demoted
    /// playlist confirms the rows that selection already moved to the bucket.
    private func replayProcessedSnapshots(
        _ snapshots: [TrackSnapshot],
        itemOwner: PlaylistRecord,
        contributedSourceMusicPlaylistID: String?,
        syncedAt: Date,
        in context: ModelContext
    ) throws -> [String] {
        try snapshots.map { snapshot in
            let trackResult = try TrackRecordRepository.upsertWithResult(snapshot, in: context)
            let itemResult = try PlaylistItemRepository.upsertWithResult(
                playlistID: itemOwner.id,
                trackID: trackResult.record.id,
                musicPlaylistEntryID: snapshot.playlistEntryID,
                in: context
            )
            if let contributedSourceMusicPlaylistID,
               itemResult.record.addSourceMusicPlaylistID(contributedSourceMusicPlaylistID) {
                itemResult.record.updatedAt = syncedAt
            }
            if Self.shouldRefreshLastSeen(
                current: itemResult.record.lastSeenInPlaylistAt,
                syncedAt: syncedAt,
                didChange: itemResult.mutation.didChange
            ) {
                itemResult.record.lastSeenInPlaylistAt = syncedAt
            }
            return trackResult.record.id.uuidString
        }
    }

    private func inactivePlaylistSummary(skippedCount: Int = 1) -> PlaylistSyncSummary {
        var summary = PlaylistSyncSummary()
        summary.skippedCount = max(skippedCount, 1)
        summary.skippedReason = "inactivePlaylist"
        return summary
    }

    /// Which playlist record owns the items a sync produces. Contributing
    /// triage playlists hand theirs to the shared bucket; everything else
    /// owns its own.
    private func itemOwner(
        for playlistRecord: PlaylistRecord,
        in context: ModelContext
    ) throws -> PlaylistRecord {
        guard playlistRecord.role == .triageSource else {
            return playlistRecord
        }

        return try PlaylistRepository.triageBucket(in: context)
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

        // A single removal rewrites the whole playlist, and the rewrite is
        // built from the possibly truncated fetch above, so the size of the
        // list actually sent is worth recording.
        try await MusicKitActivityLog.shared.measure(
            .libraryPlaylistEdit,
            magnitude: Double(remainingTracks.count),
            detail: "rewrote playlist to remove 1 track"
        ) {
            try await MusicLibrary.shared.edit(playlist, items: remainingTracks)
        }
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
        try await AppleMusicPlaylistTrackLoader.loadTracks(for: playlist)
    }

    private func snapshot(from track: Track, playlistID: String) -> TrackSnapshot {
        AppleMusicPlaylistTrackLoader.snapshot(from: track, playlistID: playlistID)
    }

    private func warmUpArtworkThemes(for snapshots: [TrackSnapshot]) {
        let tracks = snapshots.map(AlbumArtworkThemeWarmupTrack.init(snapshot:))
        Task(priority: .background) {
            await AlbumArtworkThemeWarmupService.shared.enqueue(tracks)
        }
    }
}
