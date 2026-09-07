import Foundation

struct PlaybackControlsPresentation: Equatable, Sendable {
    let isPlaying: Bool
    let isShuffling: Bool
    let isRepeatingAll: Bool

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

    var repeatAllSystemImage: String {
        "repeat"
    }

    var repeatAllTitle: String {
        "Repeat All"
    }

    var skipForwardSystemImage: String {
        "forward.fill"
    }

    var skipForwardAccessibilityLabel: String {
        "Next track"
    }
}
