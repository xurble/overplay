import Foundation
@preconcurrency import MusicKit

/// Decides when the player has genuinely finished its queue and Overplay
/// should reshuffle and restart per the always-repeat playback model.
///
/// MusicKit does not report queue completion directly: the current entry
/// drops to nil and playback stops. The same player state can also appear
/// when an external surface stops playback mid-track, so restarting
/// additionally requires the outgoing session to have been observed near
/// the end of its track.
enum PlaybackQueueEndPolicy {
    static func queueDidEnd(
        hasCurrentEntry: Bool,
        playbackStatus: MusicPlayer.PlaybackStatus,
        hasActiveQueue: Bool,
        isRestartingQueue: Bool
    ) -> Bool {
        guard !isRestartingQueue, !hasCurrentEntry, hasActiveQueue else {
            return false
        }
        return playbackStatus == .stopped || playbackStatus == .paused
    }

    static func shouldRestartAfterQueueEnd(session: TrackPlaySession?) -> Bool {
        guard let session else { return false }
        return PlaybackSessionEvaluationService.inferredNaturalCompletion(session: session)
    }

    /// A thrown skipToNextEntry is ambiguous: skipping past the final entry
    /// throws (queue exhausted — restart per the always-repeat model), but a
    /// delivery failure mid-queue throws identically. Only treat the throw
    /// as queue end when the active queue says there was nothing left to
    /// skip to, or the player has already abandoned its entry. An unknown
    /// queue position cannot rule out queue end, so it keeps the restart
    /// path (which is non-destructive until play() succeeds).
    static func skipFailureIndicatesQueueEnd(
        activeQueueIndex: Int?,
        activeQueueCount: Int,
        hasCurrentEntry: Bool
    ) -> Bool {
        guard hasCurrentEntry else { return true }
        guard let activeQueueIndex, activeQueueCount > 0 else { return true }
        return activeQueueIndex >= activeQueueCount - 1
    }
}
