import Foundation
import SwiftData

struct CarPlayNowPlayingButtonSignature: Equatable {
    var trackID: String?
    var skipCount: Int
    var isProtected: Bool
    var isEvicted: Bool
    var shuffleEnabled: Bool
    var repeatEnabled: Bool
    var skipForwardIntent: PlaybackSkipForwardIntent

    var trackActionMenuSystemImage: String {
        switch skipForwardIntent {
        case .standard, .skipCountReset:
            "info.circle.fill"
        case .countedSkip:
            "exclamationmark.triangle.fill"
        case .eviction:
            "exclamationmark.octagon.fill"
        }
    }

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
