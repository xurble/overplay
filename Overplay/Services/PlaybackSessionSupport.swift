import Foundation
import SwiftData

enum PlaybackSessionSupport {
    static func makeSession(
        trackID: String,
        localTrackID: String? = nil,
        elapsedSeconds: Double,
        durationSeconds: Double?,
        sessionStartDate: Date = .now,
        lastObservedAt: Date? = nil,
        hasEvaluated: Bool = false
    ) -> TrackPlaySession {
        TrackPlaySession(
            trackID: trackID,
            localTrackID: localTrackID,
            sessionStartDate: sessionStartDate,
            lastObservedPlaybackTime: elapsedSeconds,
            lastObservedAt: lastObservedAt ?? sessionStartDate,
            durationSeconds: durationSeconds,
            hasEvaluated: hasEvaluated
        )
    }

    static func itemMatchesMusicItemID(
        _ item: PlaylistItemRecord,
        musicItemID: String,
        in context: ModelContext
    ) throws -> Bool {
        guard let track = try TrackRecordRepository.track(id: item.trackID, in: context) else {
            return false
        }

        return PlaybackQueueBuilder.musicItemIDs(for: track).contains(musicItemID)
    }

    static func resolvePlaylistItem(
        forMusicItemID musicItemID: String,
        currentPlaylistItem: PlaylistItemRecord?,
        playlist: PlaylistRecord,
        in context: ModelContext
    ) throws -> PlaylistItemRecord? {
        if let currentPlaylistItem,
           currentPlaylistItem.playlistID == playlist.id,
           try itemMatchesMusicItemID(currentPlaylistItem, musicItemID: musicItemID, in: context) {
            if let liveItem = try PlaylistItemRepository.item(id: currentPlaylistItem.id, in: context),
               liveItem.playlistID == playlist.id,
               try itemMatchesMusicItemID(liveItem, musicItemID: musicItemID, in: context) {
                return liveItem
            }

            if let liveItem = try PlaylistItemRepository.item(
                playlistID: playlist.id,
                trackID: currentPlaylistItem.trackID,
                in: context
            ),
               try itemMatchesMusicItemID(liveItem, musicItemID: musicItemID, in: context) {
                return liveItem
            }
        }

        // Fast path: one indexed catalog/library track lookup plus one
        // indexed item fetch covers the common case.
        if let track = try TrackRecordRepository.track(musicItemID: musicItemID, in: context),
           let item = try PlaylistItemRepository.item(
               playlistID: playlist.id,
               trackID: track.id,
               in: context
           ) {
            return item
        }

        // True last resort: the full scan also matches IDs embedded in a
        // record's stored MusicKit playback data, which the indexed
        // catalog/library fields may not cover.
        let items = try PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context)
        let tracks = try TrackRecordRepository.tracks(ids: items.map(\.trackID), in: context)
        let tracksByID = tracks.firstValueDictionary(keyedBy: \.id)
        return PlaybackQueueBuilder.playlistItem(
            matching: musicItemID,
            items: items,
            tracksByID: tracksByID
        )
    }
}
