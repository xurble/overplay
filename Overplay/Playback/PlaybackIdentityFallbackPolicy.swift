import Foundation

enum PlaybackIdentityFallbackPolicy {
    static func shouldUseActiveQueueFallback(
        queueReportedTrackID: String,
        activeQueueMusicItemID: String?,
        isModeQueueRebuildPending: Bool
    ) -> Bool {
        guard !isModeQueueRebuildPending else { return false }
        return queueReportedTrackID == activeQueueMusicItemID
    }

    /// Whether the resolved playback identity moved to a different track.
    ///
    /// Local track IDs are authoritative when both sides carry one. Without
    /// them, a raw MusicKit ID mismatch can be the same track reported
    /// through the other ID domain (catalog vs. library) — treating that as
    /// a track change would evaluate the still-playing session mid-track and
    /// fabricate a skip. When both raw IDs belong to the current track's
    /// known ID set, the identity has not changed.
    static func identityDidChange(
        oldMusicItemID: String?,
        oldLocalTrackID: String?,
        newMusicItemID: String?,
        newLocalTrackID: String?,
        currentTrackKnownMusicItemIDs: @autoclosure () -> Set<String>
    ) -> Bool {
        guard let oldMusicItemID, let newMusicItemID else { return false }
        if let oldLocalTrackID, let newLocalTrackID {
            return oldLocalTrackID != newLocalTrackID
        }
        if oldMusicItemID == newMusicItemID {
            return false
        }

        let knownMusicItemIDs = currentTrackKnownMusicItemIDs()
        return !(knownMusicItemIDs.contains(oldMusicItemID) && knownMusicItemIDs.contains(newMusicItemID))
    }
}
