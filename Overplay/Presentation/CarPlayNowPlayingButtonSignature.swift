import Foundation
import SwiftData

struct CarPlayNowPlayingButtonSignature: Equatable {
    var trackID: String?
    var playlistRole: PlaylistRole? = nil
    var skipCount: Int
    var isProtected: Bool
    var isEvicted: Bool

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
