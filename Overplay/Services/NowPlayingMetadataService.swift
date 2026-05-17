import Foundation
import MediaPlayer

@MainActor
enum NowPlayingMetadataService {
    static func update(track: TrackedTrack?, elapsed: Double, isPlaying: Bool) {
        guard let track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let albumTitle = track.albumTitle {
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }
        if let durationSeconds = track.durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
