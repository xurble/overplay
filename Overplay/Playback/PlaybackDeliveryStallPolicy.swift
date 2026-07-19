import Foundation
@preconcurrency import MusicKit

/// Detects streaming-delivery stalls from consecutive 1 Hz monitor ticks.
///
/// MusicKit never reports delivery failure directly: mid-track the player
/// either flips to `.interrupted`, or keeps claiming `.playing` while the
/// playback position stops advancing. A user pause/stop is never a stall,
/// and a single odd tick is never enough — the player legitimately freezes
/// briefly while buffering or transitioning between tracks.
enum PlaybackDeliveryStallPolicy {
    /// Consecutive `.interrupted` ticks before delivery counts as stalled.
    static let interruptedTickThreshold = 3
    /// Consecutive frozen-position `.playing` ticks before delivery counts
    /// as stalled. Longer than the interrupted threshold because a healthy
    /// player can sit at a fixed position while buffering.
    static let frozenPlaybackTickThreshold = 5
    /// Minimum position movement between ticks that counts as progress.
    static let progressEpsilon = 0.1
    /// Maximum automatic recovery attempts per stall episode.
    static let maximumRecoveryAttempts = 2

    struct Tick {
        var playbackStatus: MusicPlayer.PlaybackStatus
        var hasCurrentEntry: Bool
        var playbackTime: Double
    }

    struct State: Equatable {
        var interruptedTicks = 0
        var frozenTicks = 0
        var lastPlaybackTime: Double?
        /// True only when the latest tick showed witnessed forward progress
        /// (playing with an advancing position) — the signal that any
        /// previously surfaced delivery failure has genuinely cleared.
        var isProgressing = false

        var isStalled: Bool {
            interruptedTicks >= interruptedTickThreshold
                || frozenTicks >= frozenPlaybackTickThreshold
        }
    }

    static func assess(_ state: State, tick: Tick) -> State {
        var next = state
        next.isProgressing = false

        switch tick.playbackStatus {
        case .interrupted:
            next.interruptedTicks += 1
            next.frozenTicks = 0
        case .playing where tick.hasCurrentEntry:
            next.interruptedTicks = 0
            if let lastPlaybackTime = state.lastPlaybackTime,
               abs(tick.playbackTime - lastPlaybackTime) < progressEpsilon {
                next.frozenTicks += 1
            } else {
                next.frozenTicks = 0
                next.isProgressing = state.lastPlaybackTime != nil
            }
        default:
            // Paused, stopped, seeking, or playing without an entry: not a
            // stall signal (queue-end policy owns the nil-entry states),
            // but not proof of healthy delivery either.
            next.interruptedTicks = 0
            next.frozenTicks = 0
        }

        next.lastPlaybackTime = tick.playbackTime
        return next
    }

    /// Automatic recovery must never surprise the user: it only runs while
    /// the detector says delivery is stalled (unambiguous — the player still
    /// claims to be playing or interrupted, so this can never auto-play
    /// after a user-intended stop), only when Overplay itself started the
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
