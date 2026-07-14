import Foundation

/// Resolution for an optimistic track advance that is waiting for MusicKit
/// to confirm the new current entry.
enum PlaybackPendingAdvanceResolution: Equatable {
    /// The player confirmed the pending track; stop pinning and follow it.
    case arrived
    /// The player still reports the track the transition came from; keep
    /// pinning the pending identity while the skip propagates.
    case propagating
    /// The player confirmed some other track; stop pinning immediately so a
    /// wrong optimistic advance cannot hold the UI on a track that is not
    /// playing.
    case diverged
    /// The confirmation window elapsed; stop pinning.
    case expired
    /// No confirmation is available yet; keep pinning.
    case pinned
}

enum PlaybackPendingAdvancePolicy {
    static let timeoutSeconds: Double = 2

    static func resolution(
        pendingLocalTrackID: String,
        fromLocalTrackID: String?,
        confirmedLocalTrackID: String?,
        startedAt: Date,
        now: Date = .now
    ) -> PlaybackPendingAdvanceResolution {
        guard now.timeIntervalSince(startedAt) < timeoutSeconds else {
            return .expired
        }
        guard let confirmedLocalTrackID else {
            return .pinned
        }
        if confirmedLocalTrackID == pendingLocalTrackID {
            return .arrived
        }
        if confirmedLocalTrackID == fromLocalTrackID {
            return .propagating
        }
        return .diverged
    }
}
