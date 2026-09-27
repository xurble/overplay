import MusicKit

/// Only moving playback needs elapsed-time samples. Player observation remains
/// installed while idle and resumes sampling when playback starts externally.
enum PlaybackMonitorIdlePolicy {
    static func shouldSuspend(
        playbackStatus: MusicPlayer.PlaybackStatus,
        isTransitionInFlight: Bool
    ) -> Bool {
        guard !isTransitionInFlight else { return false }
        switch playbackStatus {
        case .playing, .seekingForward, .seekingBackward: return false
        default: return true
        }
    }
}
