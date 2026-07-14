import Foundation
import MusicKit
import Testing
@testable import Overplay

@Suite("Playback queue end policy")
struct PlaybackQueueEndPolicyTests {
    @Test("queue end requires no current entry, an active queue, and stopped or paused playback")
    func queueEndRequiresNoCurrentEntryAnActiveQueueAndStoppedOrPausedPlayback() {
        #expect(PlaybackQueueEndPolicy.queueDidEnd(
            hasCurrentEntry: false,
            playbackStatus: .stopped,
            hasActiveQueue: true,
            isRestartingQueue: false
        ))
        #expect(PlaybackQueueEndPolicy.queueDidEnd(
            hasCurrentEntry: false,
            playbackStatus: .paused,
            hasActiveQueue: true,
            isRestartingQueue: false
        ))
        #expect(!PlaybackQueueEndPolicy.queueDidEnd(
            hasCurrentEntry: true,
            playbackStatus: .stopped,
            hasActiveQueue: true,
            isRestartingQueue: false
        ))
        #expect(!PlaybackQueueEndPolicy.queueDidEnd(
            hasCurrentEntry: false,
            playbackStatus: .stopped,
            hasActiveQueue: false,
            isRestartingQueue: false
        ))
        #expect(!PlaybackQueueEndPolicy.queueDidEnd(
            hasCurrentEntry: false,
            playbackStatus: .stopped,
            hasActiveQueue: true,
            isRestartingQueue: true
        ))
        #expect(!PlaybackQueueEndPolicy.queueDidEnd(
            hasCurrentEntry: false,
            playbackStatus: .playing,
            hasActiveQueue: true,
            isRestartingQueue: false
        ))
    }

    @Test("restart requires a session observed near the end of its track")
    func restartRequiresASessionObservedNearTheEndOfItsTrack() {
        #expect(PlaybackQueueEndPolicy.shouldRestartAfterQueueEnd(
            session: session(elapsedSeconds: 178, durationSeconds: 180)
        ))
        #expect(!PlaybackQueueEndPolicy.shouldRestartAfterQueueEnd(
            session: session(elapsedSeconds: 60, durationSeconds: 180)
        ))
        #expect(!PlaybackQueueEndPolicy.shouldRestartAfterQueueEnd(session: nil))
    }

    private func session(elapsedSeconds: Double, durationSeconds: Double) -> TrackPlaySession {
        TrackPlaySession(
            trackID: "library-1",
            sessionStartDate: .now,
            lastObservedPlaybackTime: elapsedSeconds,
            durationSeconds: durationSeconds,
            hasEvaluated: false
        )
    }
}
