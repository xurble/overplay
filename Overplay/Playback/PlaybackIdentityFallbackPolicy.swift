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
}
