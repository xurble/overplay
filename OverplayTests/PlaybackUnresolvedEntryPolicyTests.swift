import Foundation
import Testing
@testable import Overplay

@Suite("Playback unresolved entry policy")
struct PlaybackUnresolvedEntryPolicyTests {
    @Test("a single unresolved tick is not divergence")
    func aSingleUnresolvedTickIsNotDivergence() {
        // The whole point: one observation used to clear playback state,
        // which left playback running with no way to pause it.
        let state = PlaybackUnresolvedEntryPolicy.assess(
            PlaybackUnresolvedEntryPolicy.State(),
            hasUnresolvedConcreteEntry: true
        )

        #expect(state.unresolvedTicks == 1)
        #expect(!state.hasDiverged)
    }

    @Test("divergence needs the condition to persist to the threshold")
    func divergenceNeedsTheConditionToPersistToTheThreshold() {
        var state = PlaybackUnresolvedEntryPolicy.State()

        for tick in 1...PlaybackUnresolvedEntryPolicy.unresolvedTickThreshold {
            state = PlaybackUnresolvedEntryPolicy.assess(state, hasUnresolvedConcreteEntry: true)
            let expected = tick >= PlaybackUnresolvedEntryPolicy.unresolvedTickThreshold
            #expect(state.hasDiverged == expected, "tick \(tick)")
        }
    }

    @Test("resolving an identity resets the counter")
    func resolvingAnIdentityResetsTheCounter() {
        var state = PlaybackUnresolvedEntryPolicy.State()
        state = PlaybackUnresolvedEntryPolicy.assess(state, hasUnresolvedConcreteEntry: true)
        state = PlaybackUnresolvedEntryPolicy.assess(state, hasUnresolvedConcreteEntry: true)
        #expect(state.unresolvedTicks == 2)

        state = PlaybackUnresolvedEntryPolicy.assess(state, hasUnresolvedConcreteEntry: false)

        #expect(state.unresolvedTicks == 0)
        #expect(!state.hasDiverged)
    }

    @Test("a hydration spell shorter than the threshold never diverges")
    func aHydrationSpellShorterThanTheThresholdNeverDiverges() {
        // The reported failure: Apple Music's services were contended for
        // seconds while Overplay enumerated the playlist library, so the
        // player reported an entry it had not yet hydrated.
        var state = PlaybackUnresolvedEntryPolicy.State()

        for _ in 0..<20 {
            for _ in 1..<PlaybackUnresolvedEntryPolicy.unresolvedTickThreshold {
                state = PlaybackUnresolvedEntryPolicy.assess(state, hasUnresolvedConcreteEntry: true)
                #expect(!state.hasDiverged)
            }
            state = PlaybackUnresolvedEntryPolicy.assess(state, hasUnresolvedConcreteEntry: false)
            #expect(!state.hasDiverged)
        }
    }

    @Test("a sustained unresolved entry stays diverged without overflowing")
    func aSustainedUnresolvedEntryStaysDivergedWithoutOverflowing() {
        var state = PlaybackUnresolvedEntryPolicy.State()

        for _ in 0..<1_000 {
            state = PlaybackUnresolvedEntryPolicy.assess(state, hasUnresolvedConcreteEntry: true)
        }

        #expect(state.hasDiverged)
        #expect(state.unresolvedTicks == PlaybackUnresolvedEntryPolicy.unresolvedTickThreshold)
    }

    @Test("recovery after divergence clears the state")
    func recoveryAfterDivergenceClearsTheState() {
        var state = PlaybackUnresolvedEntryPolicy.State()
        for _ in 1...PlaybackUnresolvedEntryPolicy.unresolvedTickThreshold {
            state = PlaybackUnresolvedEntryPolicy.assess(state, hasUnresolvedConcreteEntry: true)
        }
        #expect(state.hasDiverged)

        state = PlaybackUnresolvedEntryPolicy.assess(state, hasUnresolvedConcreteEntry: false)

        #expect(state == PlaybackUnresolvedEntryPolicy.State())
    }

    @Test("the threshold is generous enough to cover a multi-second stall")
    func theThresholdIsGenerousEnoughToCoverAMultiSecondStall() {
        // The monitor ticks at 1 Hz, so the threshold is also the number of
        // seconds of hydration Overplay tolerates.
        #expect(PlaybackUnresolvedEntryPolicy.unresolvedTickThreshold >= 3)
    }
}
