import Foundation

enum PlaybackSkipForwardIntent: Equatable, Sendable {
    case standard
    case countedSkip
    case eviction
    case skipCountReset

    var systemImage: String {
        "forward.fill"
    }

    var accessibilityLabel: String {
        "Next track"
    }
}

struct PlaybackControlsPresentation: Equatable, Sendable {
    let isPlaying: Bool
    var skipForwardIntent: PlaybackSkipForwardIntent = .standard

    var primarySystemImage: String {
        isPlaying ? "pause.fill" : "play.fill"
    }

    var primaryAccessibilityLabel: String {
        isPlaying ? "Pause" : "Play"
    }

    var shuffleSystemImage: String {
        "shuffle"
    }

    var shuffleTitle: String {
        "Shuffle"
    }

    var skipForwardSystemImage: String {
        skipForwardIntent.systemImage
    }

    var skipForwardAccessibilityLabel: String {
        skipForwardIntent.accessibilityLabel
    }
}
