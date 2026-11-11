import Foundation

/// The time `PlaybackController`'s limits and delays run on: the stuck-call
/// limit, the start hold, the queue-load wait and the network settle delay.
/// Production uses the continuous clock; tests drive it by hand, as they
/// already drive sampling through the controller's `sleep`.
struct PlaybackClock: Sendable {
    var now: @MainActor @Sendable () -> ContinuousClock.Instant
    /// Returns early, without throwing, when the task is cancelled.
    var sleep: @MainActor @Sendable (Duration) async -> Void

    static let continuous = PlaybackClock(
        now: { ContinuousClock.now },
        sleep: { try? await Task.sleep(for: $0) }
    )
}
