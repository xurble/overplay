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

    @Test("a thrown skip only means queue end at the final entry or with no live entry")
    func aThrownSkipOnlyMeansQueueEndAtTheFinalEntryOrWithNoLiveEntry() {
        // Mid-queue with a live entry: a delivery failure, not queue end.
        #expect(!PlaybackQueueEndPolicy.skipFailureIndicatesQueueEnd(
            activeQueueIndex: 3,
            activeQueueCount: 10,
            hasCurrentEntry: true,
            isShuffling: false
        ))
        // On the final entry, skipping past the end throws — queue end.
        #expect(PlaybackQueueEndPolicy.skipFailureIndicatesQueueEnd(
            activeQueueIndex: 9,
            activeQueueCount: 10,
            hasCurrentEntry: true,
            isShuffling: false
        ))
        // The player abandoned its entry — cannot rule out queue end.
        #expect(PlaybackQueueEndPolicy.skipFailureIndicatesQueueEnd(
            activeQueueIndex: 3,
            activeQueueCount: 10,
            hasCurrentEntry: false,
            isShuffling: false
        ))
        // Unknown queue position — cannot rule out queue end.
        #expect(PlaybackQueueEndPolicy.skipFailureIndicatesQueueEnd(
            activeQueueIndex: nil,
            activeQueueCount: 10,
            hasCurrentEntry: true,
            isShuffling: false
        ))
        #expect(PlaybackQueueEndPolicy.skipFailureIndicatesQueueEnd(
            activeQueueIndex: 3,
            activeQueueCount: 0,
            hasCurrentEntry: true,
            isShuffling: false
        ))
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

    @Test("a skip failure while shuffling is never read as queue end")
    func skipFailureWhileShufflingIsNeverQueueEnd() {
        // `activeQueueIndex` is a position in Overplay's local order, which is
        // the play order only while shuffle is off. MusicKit owns shuffle now,
        // so the last local index is routinely not the last track played.
        #expect(!PlaybackQueueEndPolicy.skipFailureIndicatesQueueEnd(
            activeQueueIndex: 9,
            activeQueueCount: 10,
            hasCurrentEntry: true,
            isShuffling: true
        ))

        // Same position, shuffle off: local order is the play order, so the
        // inference still holds.
        #expect(PlaybackQueueEndPolicy.skipFailureIndicatesQueueEnd(
            activeQueueIndex: 9,
            activeQueueCount: 10,
            hasCurrentEntry: true,
            isShuffling: false
        ))
    }

    @Test("an abandoned queue is queue end whether shuffling or not")
    func abandonedQueueIsQueueEndEitherWay() {
        // No current entry is unambiguous: the player has nothing left,
        // whatever order it was playing in.
        for isShuffling in [true, false] {
            #expect(PlaybackQueueEndPolicy.skipFailureIndicatesQueueEnd(
                activeQueueIndex: 3,
                activeQueueCount: 10,
                hasCurrentEntry: false,
                isShuffling: isShuffling
            ))
        }
    }
}
