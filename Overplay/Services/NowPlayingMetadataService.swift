import Foundation
import MediaPlayer

@MainActor
enum NowPlayingMetadataService {
    private static var lastPublished: NowPlayingPublishPolicy.Published?

    /// - Parameter ownsPlayback: Whether the shared player currently holds
    ///   one of Overplay's queue entries. When false Overplay has no claim
    ///   on the system Now Playing session and must not write to it.
    static func update(
        track: CurrentPlaybackTrack?,
        elapsed: Double,
        isPlaying: Bool,
        ownsPlayback: Bool
    ) {
        let identity = track.map {
            NowPlayingPublishPolicy.Identity(
                title: $0.title,
                artistName: $0.artistName,
                albumTitle: $0.albumTitle,
                durationSeconds: $0.durationSeconds,
                isPlaying: isPlaying
            )
        }
        let decision = NowPlayingPublishPolicy.decision(
            identity: identity,
            elapsedSeconds: elapsed,
            ownsPlayback: ownsPlayback,
            lastPublished: lastPublished,
            now: .now
        )

        switch decision {
        case .skip:
            return
        case .clear:
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            lastPublished = nil
            MusicKitActivityLog.shared.record(.nowPlayingInfoClear)
        case .publish:
            guard let track, let identity else { return }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info(for: track, elapsed: elapsed, isPlaying: isPlaying)
            lastPublished = NowPlayingPublishPolicy.Published(
                identity: identity,
                elapsedSeconds: elapsed,
                publishedAt: .now
            )
            MusicKitActivityLog.shared.record(
                isPlaying ? .nowPlayingInfoWrite : .nowPlayingInfoWriteWhilePaused
            )
        }
    }

    /// Drops the published-state memo without touching the system session.
    /// For tests and for a local state reset, where the next update must be
    /// evaluated from scratch.
    static func resetPublishedState() {
        lastPublished = nil
    }

    private static func info(
        for track: CurrentPlaybackTrack,
        elapsed: Double,
        isPlaying: Bool
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        if let albumTitle = track.albumTitle {
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }
        if let durationSeconds = track.durationSeconds {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }

        return info
    }
}
