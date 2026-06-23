import Foundation
@preconcurrency import MusicKit
import SwiftData

enum PlaybackTrackMetadataSync {
    struct MetadataUpdate {
        var playlistItem: PlaylistItemRecord?
        var track: CurrentPlaybackTrack?
        var shouldRefreshExistingTrack: Bool
    }

    static func metadataUpdate(
        for musicItemID: String,
        currentTrack: CurrentPlaybackTrack?,
        currentPlaylistItem: PlaylistItemRecord?,
        trustedPlaylistItem: PlaylistItemRecord? = nil,
        currentPlaylistID: String?,
        queueItem: MusicPlayer.Queue.Entry.Item?,
        in context: ModelContext
    ) -> MetadataUpdate {
        var playlistItem = trustedPlaylistItem
        if playlistItem == nil,
           let playlist = try? PlaybackTrackResolver.currentPlaylist(musicPlaylistID: currentPlaylistID, in: context),
           let resolvedItem = try? PlaybackSessionSupport.resolvePlaylistItem(
               forMusicItemID: musicItemID,
               currentPlaylistItem: currentPlaylistItem,
               playlist: playlist,
               in: context
           ) {
            playlistItem = resolvedItem
        }

        let resolvedTrack = PlaybackTrackResolver.currentPlaybackTrack(
            musicItemID: musicItemID,
            playlistItem: playlistItem,
            musicPlaylistID: currentPlaylistID,
            queueItem: queueItem,
            trustPlaylistItem: trustedPlaylistItem != nil,
            in: context
        )
        if currentTrack?.id == musicItemID {
            return MetadataUpdate(
                playlistItem: playlistItem,
                track: resolvedTrack,
                shouldRefreshExistingTrack: true
            )
        }

        return MetadataUpdate(
            playlistItem: playlistItem,
            track: resolvedTrack,
            shouldRefreshExistingTrack: false
        )
    }
}
