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
        in context: ModelContext
    ) throws -> [Track] {
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        let tracksByID = tracks.firstValueDictionary(keyedBy: \.id)
        return PlaybackQueueBuilder.cachedPlayableMusicTracks(items: items, tracksByID: tracksByID)
    }

    static func orderedQueueEntries(
        from tracks: [Track],
        playlistID: String,
        playerID: String,
        startingTrackID: String?,
        promoteStartingTrackInShuffle: Bool = false,
        retainedTrackID: String? = nil,
        in context: ModelContext
    ) throws -> [PlaybackQueueEntry] {
        let inputs = try playlistInputs(for: playlistID, in: context)
        let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: inputs.items)
        let orderedTrackIDs = PlaybackModeCoordinator.orderedTrackIDs(
            orderTracks: orderTracks,
            playerID: playerID,
            playlistID: playlistID,
            startingTrackID: startingTrackID,
            promoteStartingTrackInShuffle: promoteStartingTrackInShuffle,
            retainedTrackID: retainedTrackID
        )

        let musicTracksByLocalID = PlaybackQueueCoordinator.musicTracksByLocalID(
            tracks,
            tracksByID: inputs.tracksByID
        )
        return orderedTrackIDs.compactMap { localTrackID in
            musicTracksByLocalID[localTrackID].map {
                PlaybackQueueEntry(localTrackID: localTrackID, musicTrack: $0)
            }
        }
    }

    static func orderedCachedQueueEntries(
        for playlistID: String,
        playerID: String,
        startingTrackID: String? = nil,
        promoteStartingTrackInShuffle: Bool = false,
        retainedTrackID: String? = nil,
        in context: ModelContext
    ) throws -> [PlaybackQueueEntry] {
        let inputs = try playlistInputs(for: playlistID, in: context)
        let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: inputs.items)
        let orderedTrackIDs = PlaybackModeCoordinator.orderedTrackIDs(
            orderTracks: orderTracks,
            playerID: playerID,
            playlistID: playlistID,
            startingTrackID: startingTrackID,
            promoteStartingTrackInShuffle: promoteStartingTrackInShuffle,
            retainedTrackID: retainedTrackID
        )

        return PlaybackQueueCoordinator.cachedEntries(
            orderedTrackIDs: orderedTrackIDs,
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
        return PlaybackModeCoordinator.orderedTrackIDs(
            orderTracks: orderTracks,
            playerID: playerID,
            playlistID: playlistID,
            retainedTrackID: retainedTrackID
        )
    }

    static func cachedQueueEntries(
        orderedTrackIDs: [String],
        tracksByID: [UUID: TrackRecord]
    ) -> [PlaybackQueueEntry] {
        PlaybackQueueCoordinator.cachedEntries(orderedTrackIDs: orderedTrackIDs, tracksByID: tracksByID)
    }

    static func orderedQueueTracks(
        from tracks: [Track],
        playlistID: String,
        playerID: String,
        startingTrackID: String?,
        promoteStartingTrackInShuffle: Bool = false,
        retainedTrackID: String? = nil,
        in context: ModelContext
    ) throws -> [Track] {
        let entries = try orderedQueueEntries(
            from: tracks,
            playlistID: playlistID,
            playerID: playerID,
            startingTrackID: startingTrackID,
            promoteStartingTrackInShuffle: promoteStartingTrackInShuffle,
            retainedTrackID: retainedTrackID,
            in: context
        )
        return entries.isEmpty ? tracks : entries.map(\.musicTrack)
    }

    static func queueTracks(from entries: [PlaybackQueueEntry], fallback tracks: [Track]) -> [Track] {
        PlaybackQueueCoordinator.queueTracks(from: entries, fallback: tracks)
    }

    static func repeatRestartQueueEntries(
        playlistID: String,
        playerID: String,
        lastMusicItemID: String,
        in context: ModelContext
    ) throws -> (entries: [PlaybackQueueEntry], didUpdateStoredShuffleOrder: Bool) {
        let inputs = try playlistInputs(for: playlistID, in: context)
        let orderTracks = PlaybackQueueBuilder.playbackOrderTracks(items: inputs.items)
        let lastLocalTrackID = try PlaybackQueueCoordinator.localTrackID(matching: lastMusicItemID, context: context)
        let restartOrder = PlaybackModeCoordinator.repeatRestartOrder(
            orderTracks: orderTracks,
            playerID: playerID,
            playlistID: playlistID,
            lastLocalTrackID: lastLocalTrackID
        )
        let entries = cachedQueueEntries(
            orderedTrackIDs: restartOrder.orderedTrackIDs,
            tracksByID: inputs.tracksByID
        )
        return (entries, restartOrder.didUpdateStoredShuffleOrder)
    }
}
