import Foundation
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
}
