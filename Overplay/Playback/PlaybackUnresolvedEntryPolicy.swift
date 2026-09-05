import Foundation

/// Decides when a concrete-but-unresolvable player entry has persisted long
/// enough to count as real divergence rather than MusicKit still hydrating.
///
/// `ApplicationMusicPlayer` can report a current entry before its item is
/// available — most visibly while Apple Music's library services are
/// contended, for example when Overplay itself has just asked them to
/// enumerate the whole playlist library. During that window Overplay cannot
/// correlate the entry to a local track, but nothing is actually wrong: the
/// player is playing the queue it was given.
///
/// Treating a single such observation as divergence used to clear durable
/// playback state, which left the user unable to pause and restarted the One
/// True Playlist from its first track. Every other transient player state in
/// this project is debounced — see `PlaybackDeliveryStallPolicy` and
/// `PlaybackQueueEndPolicy` — and this one is no different.
enum PlaybackUnresolvedEntryPolicy {
    /// Consecutive 1 Hz observations of an unresolvable concrete entry before
    /// Overplay accepts that the queue really has diverged. Generous, because
    /// holding a slightly stale current track costs nothing while hydration
    /// completes, whereas acting too early destroys playback state.
    static let unresolvedTickThreshold = 5

    struct State: Equatable, Sendable {
        var unresolvedTicks = 0

        /// True once the condition has persisted long enough that MusicKit
        /// hydration can no longer explain it.
        var hasDiverged: Bool {
            unresolvedTicks >= unresolvedTickThreshold
        }
    }

    /// - Parameter hasUnresolvedConcreteEntry: The player reports a current
    ///   entry that Overplay cannot resolve to an identity on this tick.
    static func assess(_ state: State, hasUnresolvedConcreteEntry: Bool) -> State {
        guard hasUnresolvedConcreteEntry else {
            return State()
        }

        var next = state
        // Saturate rather than counting forever, so a long unresolved spell
        // cannot overflow and so the state stays comparable.
        next.unresolvedTicks = min(state.unresolvedTicks + 1, unresolvedTickThreshold)
        return next
    }
}
