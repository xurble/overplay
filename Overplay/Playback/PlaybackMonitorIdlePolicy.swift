import Foundation

/// Decides when the 1 Hz playback monitor should suspend itself. Once
/// playback has been paused/stopped for the timeout, ticking is pure waste
/// (each tick runs SwiftData fetches on the main actor). Every play path
/// calls startMonitoring, which resumes the loop, so suspension is safe.
/// A delivery stall keeps the monitor alive: its ticks drive the bounded
/// auto-recovery attempts.
enum PlaybackMonitorIdlePolicy {
    static let idleTimeoutSeconds: TimeInterval = 300

    static func updatedIdleStart(
        current: Date?,
        isPlaying: Bool,
        isDeliveryStalled: Bool,
        now: Date
    ) -> Date? {
        if isPlaying || isDeliveryStalled {
            return nil
        }
        return current ?? now
    }

    static func shouldSuspend(idleSince: Date?, now: Date) -> Bool {
        guard let idleSince else { return false }
        return now.timeIntervalSince(idleSince) >= idleTimeoutSeconds
    }
}
