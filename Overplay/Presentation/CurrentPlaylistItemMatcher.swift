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

        let musicItemIDs = PlaybackQueueBuilder.musicItemIDs(for: track)
        let matchesMusicID = musicItemIDs.contains(currentTrack.id)
        if matchesMusicID {
            TrackMetadataDiagnostics.log(
                "current row matched by music item id playlist=\(TrackMetadataDiagnostics.describe(playlist)) rowItemID=\(itemID.uuidString) rowTrackID=\(track.id.uuidString) rowMusicIDs=\(musicItemIDs.joined(separator: ",")) currentItem=\(TrackMetadataDiagnostics.describe(currentPlaylistItem)) currentTrack=\(TrackMetadataDiagnostics.describe(currentTrack))"
            )
        }
        return matchesMusicID
    }
}
