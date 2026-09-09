import Foundation
@preconcurrency import MusicKit

/// Detects streaming-delivery stalls from consecutive 1 Hz monitor ticks.
///
/// MusicKit does not report a frozen stream directly: mid-track the player
/// can keep claiming `.playing` while the playback position stops advancing.
/// An interruption belongs to the system, and a user pause/stop is never a
/// stall. A single odd tick is never enough — the player legitimately freezes
/// briefly while buffering or transitioning between tracks.
enum PlaybackDeliveryStallPolicy {
    /// Consecutive frozen-position `.playing` ticks before delivery counts
    /// as stalled. A healthy player can sit at a fixed position briefly
    /// while buffering.
    static let frozenPlaybackTickThreshold = 5
    /// Minimum position movement between ticks that counts as progress.
    static let progressEpsilon = 0.1
    /// Maximum automatic recovery attempts per stall episode.
    static let maximumRecoveryAttempts = 2
    /// Consecutive progressing ticks before a stall episode counts as over
    /// and its recovery budget may be refilled. One good tick is not enough:
    /// a player that stutters — a moment of progress, then frozen again —
    /// would otherwise refill the budget forever and let Overplay re-prod
    /// the shared player indefinitely.
    static let recoveredProgressTickThreshold = 5

    struct Tick {
        var playbackStatus: MusicPlayer.PlaybackStatus
        var hasCurrentEntry: Bool
        var playbackTime: Double
    }

    struct State: Equatable {
        var frozenTicks = 0
        var lastPlaybackTime: Double?
        /// True only when the latest tick showed witnessed forward progress
        /// (playing with an advancing position) — the signal that any
        /// previously surfaced delivery failure has genuinely cleared.
        var isProgressing = false
        /// Consecutive progressing ticks observed so far.
        var progressingTicks = 0

        var isStalled: Bool {
            frozenTicks >= frozenPlaybackTickThreshold
        }

        /// Whether delivery has progressed for long enough that the stall
        /// episode is over and its recovery budget can be refilled.
        var hasRecoveredFromStall: Bool {
            progressingTicks >= recoveredProgressTickThreshold
        }
    }

    static func assess(_ state: State, tick: Tick) -> State {
        var next = state
        next.isProgressing = false

        switch tick.playbackStatus {
        case .interrupted:
            next.frozenTicks = 0
            next.progressingTicks = 0
        case .playing where tick.hasCurrentEntry:
            if let lastPlaybackTime = state.lastPlaybackTime,
               abs(tick.playbackTime - lastPlaybackTime) < progressEpsilon {
                next.frozenTicks += 1
                next.progressingTicks = 0
            } else {
                next.frozenTicks = 0
                next.isProgressing = state.lastPlaybackTime != nil
                next.progressingTicks = next.isProgressing ? state.progressingTicks + 1 : 0
            }
        default:
            // Paused, stopped, seeking, or playing without an entry: not a
            // stall signal (queue-end policy owns the nil-entry states),
            // but not proof of healthy delivery either.
            next.frozenTicks = 0
            next.progressingTicks = 0
        }

        next.lastPlaybackTime = tick.playbackTime
        return next
    }

    /// Automatic recovery must never surprise the user: it only runs while
    /// the detector says delivery is stalled (unambiguous — the player still
    /// claims to be playing, so this can never auto-play after a user-intended
    /// stop), only when Overplay itself started the
    /// playback, only when a network path is available, and only a bounded
    /// number of times per stall episode.
    static func shouldAttemptRecovery(
        state: State,
        playbackIntended: Bool,
        isNetworkReachable: Bool,
        attemptsMade: Int
    ) -> Bool {
        state.isStalled
            && playbackIntended
            && isNetworkReachable
            && attemptsMade < maximumRecoveryAttempts
    }
}
