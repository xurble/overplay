import Foundation

enum CurrentPlaylistItemMatcher {
    static func isCurrent(
        itemID: UUID,
        track: TrackRecord,
        playlist: PlaylistRecord,
        currentPlaylistID: String?,
        currentPlaylistItem: PlaylistItemRecord?,
        currentTrack: CurrentPlaybackTrack?
    ) -> Bool {
        guard let currentTrack,
              playlist.musicPlaylistID == currentPlaylistID else { return false }

        if currentPlaylistItem?.id == itemID {
            return true
        }

        if currentPlaylistItem?.trackID == track.id {
            return true
        }

        return PlaybackQueueBuilder.musicItemIDs(for: track).contains(currentTrack.id)
    }
}
