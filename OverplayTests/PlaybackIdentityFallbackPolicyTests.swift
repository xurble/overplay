import Testing
@testable import Overplay

struct PlaybackIdentityFallbackPolicyTests {
    @Test("active queue fallback only applies to the same reported MusicKit item")
    func activeQueueFallbackRequiresMatchingReportedItem() {
        #expect(PlaybackIdentityFallbackPolicy.shouldUseActiveQueueFallback(
            queueReportedTrackID: "music-current",
            activeQueueMusicItemID: "music-current",
            isModeQueueRebuildPending: false
        ))

        #expect(!PlaybackIdentityFallbackPolicy.shouldUseActiveQueueFallback(
            queueReportedTrackID: "music-carplay-advanced",
            activeQueueMusicItemID: "music-stale",
            isModeQueueRebuildPending: false
        ))
    }

    @Test("active queue fallback is disabled during mode queue rebuilds")
    func activeQueueFallbackWaitsForModeRebuild() {
        #expect(!PlaybackIdentityFallbackPolicy.shouldUseActiveQueueFallback(
            queueReportedTrackID: "music-current",
            activeQueueMusicItemID: "music-current",
            isModeQueueRebuildPending: true
        ))
    }
}
