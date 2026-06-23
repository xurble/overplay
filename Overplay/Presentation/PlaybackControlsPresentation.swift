import Foundation

enum PlaybackSkipForwardIntent: Equatable, Sendable {
    case standard
    case countedSkip
    case eviction
    case skipCountReset

    var systemImage: String {
        switch self {
        case .standard:
            "forward.fill"
        case .countedSkip:
            "exclamationmark.triangle.fill"
        case .eviction:
            "trash.fill"
        case .skipCountReset:
            "cross.case.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .standard:
            "Next track"
        case .countedSkip:
            "Next track, skip will count"
        case .eviction:
            "Next track, track will be evicted"
        case .skipCountReset:
            "Next track, skip count will reset"
        }
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
