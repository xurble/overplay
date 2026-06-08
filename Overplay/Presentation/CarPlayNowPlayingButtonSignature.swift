import Foundation

struct CarPlayNowPlayingButtonSignature: Equatable {
    var trackID: String?
    var skipCount: Int
    var isProtected: Bool
    var isEvicted: Bool
    var shuffleEnabled: Bool
    var repeatEnabled: Bool

    static func make(
        playbackController: PlaybackController,
        settings: OverplaySettings
    ) -> Self {
        NowPlayingPresentationFactory.carPlayButtonSignature(
            playbackController: playbackController,
            settings: settings
        )
    }
}
