import Foundation
import SwiftData

enum PlaybackRestorationService {
    struct DisplayRestoreState {
        var musicPlaylistID: String
        var playlistItem: PlaylistItemRecord?
        var track: CurrentPlaybackTrack
        var elapsedSeconds: Double
        var durationSeconds: Double?
        var activeSession: TrackPlaySession
    }

    static func displayRestoreState(
        from state: LocalPlaybackState,
        in context: ModelContext
    ) throws -> DisplayRestoreState? {
        guard let playlist = try PlaylistRepository.playlist(musicPlaylistID: state.playlistID, in: context),
              let restored = try PlaybackTrackResolver.restoredTrackAndItem(
                  from: state,
                  playlist: playlist,
                  in: context
              ) else {
            return nil
        }

        return DisplayRestoreState(
            musicPlaylistID: playlist.musicPlaylistID,
            playlistItem: restored.item,
            track: CurrentPlaybackTrack(
                restored.track,
                musicItemID: state.musicItemID,
                item: restored.item
            ),
            elapsedSeconds: state.elapsedSeconds,
            durationSeconds: restored.track.durationSeconds,
            activeSession: PlaybackSessionSupport.makeSession(
                trackID: state.musicItemID,
                localTrackID: state.localTrackID,
                elapsedSeconds: state.elapsedSeconds,
                durationSeconds: restored.track.durationSeconds,
                sessionStartDate: state.updatedAt
            )
        )
    }
}
