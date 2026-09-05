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
    ///
    /// Since the queue is delivered a window at a time, sitting at the end of
    /// the correlated queue no longer implies the end of the playlist: with
    /// entries still to hand over, a throw there is a delivery failure, and
    /// treating it as queue end would reshuffle and overwrite the stored
    /// order, losing the user's place mid-playlist.
    static func skipFailureIndicatesQueueEnd(
        activeQueueIndex: Int?,
        activeQueueCount: Int,
        hasCurrentEntry: Bool,
        hasUndeliveredEntries: Bool = false
    ) -> Bool {
        guard hasCurrentEntry else { return true }
        guard !hasUndeliveredEntries else { return false }
        guard let activeQueueIndex, activeQueueCount > 0 else { return true }
        return activeQueueIndex >= activeQueueCount - 1
    }
}
