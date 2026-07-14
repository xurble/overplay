import Foundation

struct PlaybackControlsPresentation: Equatable, Sendable {
    let isPlaying: Bool

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
        "forward.fill"
    }

    var skipForwardAccessibilityLabel: String {
        "Next track"
    }
}
