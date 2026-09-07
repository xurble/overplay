import Foundation
@preconcurrency import MusicKit
import SwiftData

struct CarPlayNowPlayingButtonSignature: Equatable {
    var trackID: String?
    var playlistRole: PlaylistRole? = nil
    var skipCount: Int
    var isEvicted: Bool
    /// Rendered by the shuffle and repeat buttons, so a change here has to
    /// invalidate the signature or CarPlay never redraws them.
    var isShuffling: Bool = false
    var repeatMode: MusicPlayer.RepeatMode = MusicPlayer.RepeatMode.none

    static func make(
        playbackController: PlaybackController,
        settings: OverplaySettings,
        context: ModelContext
    ) -> Self {
        NowPlayingPresentationFactory.carPlayButtonSignature(
            playbackController: playbackController,
            settings: settings,
            context: context
        )
    }
}
