import Foundation

struct PlaybackControlsPresentation: Equatable, Sendable {
    let isPlaying: Bool
    let shuffleEnabled: Bool
    let repeatEnabled: Bool

    var primarySystemImage: String {
        isPlaying ? "pause.fill" : "play.fill"
    }

    var primaryAccessibilityLabel: String {
        isPlaying ? "Pause" : "Play"
    }

    var shuffleSystemImage: String {
        shuffleEnabled ? "shuffle.circle.fill" : "shuffle"
    }

    var shuffleTitle: String {
        "Shuffle"
    }

    var repeatModeTitle: String {
        repeatEnabled ? "All" : "Off"
    }

    var repeatTitle: String {
        "Repeat \(repeatModeTitle)"
    }

    var repeatSystemImage: String {
        "repeat"
    }
}
