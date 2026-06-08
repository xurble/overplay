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
        guard playlist.musicPlaylistID == currentPlaylistID else { return false }

        if currentPlaylistItem?.id == itemID {
            return true
        }

        guard currentPlaylistItem == nil else { return false }
        return currentTrack?.id == track.catalogID || currentTrack?.id == track.libraryID
    }
}
