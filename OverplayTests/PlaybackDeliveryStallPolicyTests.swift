import Foundation
import MusicKit
import Testing
@testable import Overplay

@Suite("Playback delivery stall policy")
struct PlaybackDeliveryStallPolicyTests {
    @Test("consecutive interrupted ticks trip the stall threshold")
    func consecutiveInterruptedTicksTripTheStallThreshold() {
        var state = PlaybackDeliveryStallPolicy.State()
        for tickCount in 1...PlaybackDeliveryStallPolicy.interruptedTickThreshold {
            state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.interrupted, playbackTime: 42))
            #expect(state.isStalled == (tickCount >= PlaybackDeliveryStallPolicy.interruptedTickThreshold))
        }
    }

    @Test("frozen-position playing ticks trip the stall threshold")
    func frozenPositionPlayingTicksTripTheStallThreshold() {
        var state = PlaybackDeliveryStallPolicy.State()
        // First tick establishes the baseline position.
        state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.playing, playbackTime: 42))
        #expect(!state.isStalled)

        for tickCount in 1...PlaybackDeliveryStallPolicy.frozenPlaybackTickThreshold {
            state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.playing, playbackTime: 42))
            #expect(state.isStalled == (tickCount >= PlaybackDeliveryStallPolicy.frozenPlaybackTickThreshold))
            #expect(!state.isProgressing)
        }
    }

    @Test("advancing playback resets counters and reports progress")
    func advancingPlaybackResetsCountersAndReportsProgress() {
        var state = PlaybackDeliveryStallPolicy.State()
        state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.interrupted, playbackTime: 42))
        state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.interrupted, playbackTime: 42))
        state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.playing, playbackTime: 43))

        #expect(!state.isStalled)
        #expect(state.isProgressing)
        #expect(state.interruptedTicks == 0)
        #expect(state.frozenTicks == 0)
    }

    @Test("the first playing tick is not progress until a position delta is witnessed")
    func theFirstPlayingTickIsNotProgressUntilAPositionDeltaIsWitnessed() {
        var state = PlaybackDeliveryStallPolicy.State()
        state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.playing, playbackTime: 42))
        #expect(!state.isProgressing)

        state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.playing, playbackTime: 43))
        #expect(state.isProgressing)
    }

    @Test("pause and stop are never stall signals")
    func pauseAndStopAreNeverStallSignals() {
        var state = PlaybackDeliveryStallPolicy.State()
        for _ in 0..<20 {
            state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.paused, playbackTime: 42))
            state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.stopped, playbackTime: 42))
        }

        #expect(!state.isStalled)
        #expect(!state.isProgressing)
    }

    @Test("a pause between interruptions restarts the count")
    func aPauseBetweenInterruptionsRestartsTheCount() {
        var state = PlaybackDeliveryStallPolicy.State()
        for _ in 0..<(PlaybackDeliveryStallPolicy.interruptedTickThreshold - 1) {
            state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.interrupted, playbackTime: 42))
        }
        state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.paused, playbackTime: 42))
        state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.interrupted, playbackTime: 42))

        #expect(!state.isStalled)
    }

    @Test("playing without a current entry is not a frozen-position stall")
    func playingWithoutACurrentEntryIsNotAFrozenPositionStall() {
        var state = PlaybackDeliveryStallPolicy.State()
        for _ in 0..<20 {
            state = PlaybackDeliveryStallPolicy.assess(
                state,
                tick: tick(.playing, playbackTime: 42, hasCurrentEntry: false)
            )
        }

        #expect(!state.isStalled)
    }

    @Test("recovery requires a stall, playback intent, a network path, and remaining attempts")
    func recoveryRequiresAStallPlaybackIntentANetworkPathAndRemainingAttempts() {
        let stalled = stalledState()
        #expect(PlaybackDeliveryStallPolicy.shouldAttemptRecovery(
            state: stalled, playbackIntended: true, isNetworkReachable: true, attemptsMade: 0
        ))
        #expect(!PlaybackDeliveryStallPolicy.shouldAttemptRecovery(
            state: PlaybackDeliveryStallPolicy.State(), playbackIntended: true, isNetworkReachable: true, attemptsMade: 0
        ))
        #expect(!PlaybackDeliveryStallPolicy.shouldAttemptRecovery(
            state: stalled, playbackIntended: false, isNetworkReachable: true, attemptsMade: 0
        ))
        #expect(!PlaybackDeliveryStallPolicy.shouldAttemptRecovery(
            state: stalled, playbackIntended: true, isNetworkReachable: false, attemptsMade: 0
        ))
        #expect(!PlaybackDeliveryStallPolicy.shouldAttemptRecovery(
            state: stalled,
            playbackIntended: true,
            isNetworkReachable: true,
            attemptsMade: PlaybackDeliveryStallPolicy.maximumRecoveryAttempts
        ))
    }

    private func tick(
        _ status: MusicPlayer.PlaybackStatus,
        playbackTime: Double,
        hasCurrentEntry: Bool = true
    ) -> PlaybackDeliveryStallPolicy.Tick {
        PlaybackDeliveryStallPolicy.Tick(
            playbackStatus: status,
            hasCurrentEntry: hasCurrentEntry,
            playbackTime: playbackTime
        )
    }

    private func stalledState() -> PlaybackDeliveryStallPolicy.State {
        var state = PlaybackDeliveryStallPolicy.State()
        for _ in 0..<PlaybackDeliveryStallPolicy.interruptedTickThreshold {
            state = PlaybackDeliveryStallPolicy.assess(state, tick: tick(.interrupted, playbackTime: 42))
        }
        return state
    }
}
