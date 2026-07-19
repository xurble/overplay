import Foundation
@preconcurrency import MusicKit
import SwiftData

enum PlaybackQueueOrchestrator {
    struct PlaylistInputs {
        var playlist: PlaylistRecord
        var items: [PlaylistItemRecord]
        var tracksByID: [UUID: TrackRecord]
    }

    static func playlistInputs(
        for playlistID: String,
        in context: ModelContext
    ) throws -> PlaylistInputs {
        guard let playlist = try PlaylistRepository.playlist(musicPlaylistID: playlistID, in: context) else {
            throw PlaylistSyncError.playlistNotFound
        }

        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        return PlaylistInputs(
            playlist: playlist,
            items: items,
            tracksByID: tracks.firstValueDictionary(keyedBy: \.id)
        )
    }

    static func cachedPlayableMusicTracks(
        for playlist: PlaylistRecord,
        scope: PlaylistPlaybackScope = .active,
        in context: ModelContext
    ) throws -> [Track] {
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        let tracksByID = tracks.firstValueDictionary(keyedBy: \.id)
        return PlaybackQueueBuilder.cachedPlayableMusicTracks(items: items, tracksByID: tracksByID, scope: scope)
    }

    static func orderedQueueEntries(
        from tracks: [Track],
        playlistID: String,
        playerID: String,
        startingTrackID: String?,
        scope: PlaylistPlaybackScope = .active,
        retainedTrackID: String? = nil,
        in context: ModelContext
    ) throws -> [PlaybackQueueEntry] {
        let inputs = try playlistInputs(for: playlistID, in: context)
        let scopedItems = inputs.items.filter { scope.includes($0) }
        let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: scopedItems, scope: scope)
        let orderedTrackIDs = PlaybackOrderCoordinator.orderedTrackIDs(
            orderTracks: orderTracks,
            playerID: playerID,
            playlistID: scope.playbackOrderPlaylistID(for: playlistID),
            retainedTrackID: retainedTrackID ?? startingTrackID
        )

        let musicTracksByLocalID = PlaybackQueueCoordinator.musicTracksByLocalID(
            tracks,
            tracksByID: inputs.tracksByID
        )
        let itemsByTrackID = scopedItems.firstValueDictionary(keyedBy: \.trackID)
        return orderedTrackIDs.compactMap { localTrackID in
            guard let trackID = UUID(uuidString: localTrackID),
                  let item = itemsByTrackID[trackID],
                  let musicTrack = musicTracksByLocalID[localTrackID] else {
                return nil
            }

            return PlaybackQueueEntry(
                playlistItemID: item.id,
                localTrackID: localTrackID,
                queuedMusicItemID: musicTrack.id.rawValue,
                musicTrack: musicTrack
            )
        }
    }

    static func orderedCachedQueueEntries(
        for playlistID: String,
        playerID: String,
        startingTrackID: String? = nil,
        scope: PlaylistPlaybackScope = .active,
        retainedTrackID: String? = nil,
        in context: ModelContext
    ) throws -> [PlaybackQueueEntry] {
        let inputs = try playlistInputs(for: playlistID, in: context)
        let scopedItems = inputs.items.filter { scope.includes($0) }
        let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: scopedItems, scope: scope)
        let orderedTrackIDs = PlaybackOrderCoordinator.orderedTrackIDs(
            orderTracks: orderTracks,
            playerID: playerID,
            playlistID: scope.playbackOrderPlaylistID(for: playlistID),
            retainedTrackID: retainedTrackID ?? startingTrackID
        )

        return PlaybackQueueCoordinator.cachedEntries(
            orderedTrackIDs: orderedTrackIDs,
            itemsByTrackID: scopedItems.firstValueDictionary(keyedBy: \.trackID),
            tracksByID: inputs.tracksByID
        )
    }

    static func orderedLocalTrackIDs(
        for playlistID: String,
        playerID: String,
        retaining retainedTrackID: String?,
        in context: ModelContext
    ) throws -> [String] {
        let inputs = try playlistInputs(for: playlistID, in: context)
        let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: inputs.items)
        return PlaybackOrderCoordinator.orderedTrackIDs(
            orderTracks: orderTracks,
            playerID: playerID,
            playlistID: playlistID,
            retainedTrackID: retainedTrackID
        )
    }

    static func localTrackID(
        matching musicItemID: String,
        playlistID: String,
        in context: ModelContext
    ) throws -> String? {
        let inputs = try playlistInputs(for: playlistID, in: context)
        return PlaybackQueueBuilder.localTrackID(
            matching: musicItemID,
            tracksByID: inputs.tracksByID
        )
    }

    static func cachedQueueEntries(
        orderedTrackIDs: [String],
        itemsByTrackID: [UUID: PlaylistItemRecord],
        tracksByID: [UUID: TrackRecord]
    ) -> [PlaybackQueueEntry] {
        PlaybackQueueCoordinator.cachedEntries(
            orderedTrackIDs: orderedTrackIDs,
            itemsByTrackID: itemsByTrackID,
            tracksByID: tracksByID
        )
    }

    static func orderedQueueTracks(
        from tracks: [Track],
        playlistID: String,
        playerID: String,
        startingTrackID: String?,
        scope: PlaylistPlaybackScope = .active,
        retainedTrackID: String? = nil,
        in context: ModelContext
    ) throws -> [Track] {
        let entries = try orderedQueueEntries(
            from: tracks,
            playlistID: playlistID,
            playerID: playerID,
            startingTrackID: startingTrackID,
            scope: scope,
            retainedTrackID: retainedTrackID,
            in: context
        )
        return entries.isEmpty ? tracks : entries.map(\.musicTrack)
    }

    static func queueTracks(from entries: [PlaybackQueueEntry], fallback tracks: [Track]) -> [Track] {
        PlaybackQueueCoordinator.queueTracks(from: entries, fallback: tracks)
    }

    struct ReshuffledQueue {
        var orderedTrackIDs: [String]
        var entries: [PlaybackQueueEntry]
    }

    /// Computes a reshuffled order and its playable entries without saving
    /// the order. A restart that replaces the live player queue must not
    /// destroy the stored order until the player has confirmed it can play
    /// the new queue — persist via `persistReshuffledOrder` only after
    /// `play()` succeeds.
    static func previewedReshuffledQueue(
        playlistID: String,
        playerID: String,
        scope: PlaylistPlaybackScope = .active,
        avoiding avoidedLocalTrackID: String?,
        in context: ModelContext
    ) throws -> ReshuffledQueue {
        let inputs = try playlistInputs(for: playlistID, in: context)
        let scopedItems = inputs.items.filter { scope.includes($0) }
        let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: scopedItems, scope: scope)
        let orderedTrackIDs = PlaybackOrderEngine.reshuffledOrder(
            for: orderTracks,
            avoiding: avoidedLocalTrackID
        )
        return ReshuffledQueue(
            orderedTrackIDs: orderedTrackIDs,
            entries: cachedQueueEntries(
                orderedTrackIDs: orderedTrackIDs,
                itemsByTrackID: scopedItems.firstValueDictionary(keyedBy: \.trackID),
                tracksByID: inputs.tracksByID
            )
        )
    }

    static func persistReshuffledOrder(
        _ orderedTrackIDs: [String],
        playlistID: String,
        playerID: String,
        scope: PlaylistPlaybackScope = .active,
        defaults: UserDefaults = .standard
    ) {
        PlaybackOrderStore.save(
            PlaybackOrderState(
                playerID: playerID,
                musicPlaylistID: scope.playbackOrderPlaylistID(for: playlistID),
                orderedTrackIDs: orderedTrackIDs
            ),
            to: defaults,
            flushImmediately: true
        )
    }
}
