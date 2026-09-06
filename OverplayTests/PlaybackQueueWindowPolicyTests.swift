import Foundation
import Testing
@testable import Overplay

@Suite("Playback queue windowing")
struct PlaybackQueueWindowPolicyTests {
    private let policy = PlaybackQueueWindowPolicy(windowSize: 5, topUpThreshold: 2, topUpBatchSize: 3)

    @Test("a playlist shorter than the window is handed over whole")
    func shortPlaylistIsHandedOverWhole() {
        let split = policy.split(entryCount: 4, startIndex: 0)
        #expect(split.delivered == 0..<4)
        #expect(split.pending.isEmpty)
    }

    @Test("a long playlist hands over only the window and holds back the rest")
    func longPlaylistHandsOverOnlyTheWindow() {
        let split = policy.split(entryCount: 100, startIndex: 0)
        #expect(split.delivered == 0..<5)
        #expect(split.pending == 5..<100)
    }

    @Test("starting part-way through queues from that track, as Apple Music does")
    func startingPartWayThroughQueuesFromThatTrack() {
        let split = policy.split(entryCount: 100, startIndex: 40)
        #expect(split.delivered == 40..<45)
        #expect(split.pending == 45..<100)
    }

    @Test("a start index past the end is clamped instead of trapping")
    func startIndexPastTheEndIsClamped() {
        let split = policy.split(entryCount: 3, startIndex: 99)
        #expect(split.delivered == 2..<3)
        #expect(split.pending.isEmpty)
        #expect(policy.split(entryCount: 0, startIndex: 0).delivered.isEmpty)
    }

    @Test("no top-up while the delivered window still has room ahead")
    func noTopUpWhileTheWindowHasRoomAhead() {
        #expect(policy.topUpCount(remainingAhead: 4, pendingCount: 50) == 0)
        #expect(policy.topUpCount(remainingAhead: 3, pendingCount: 50) == 0)
    }

    @Test("top-up fires once the remaining entries reach the threshold")
    func topUpFiresAtTheThreshold() {
        #expect(policy.topUpCount(remainingAhead: 2, pendingCount: 50) == 3)
        #expect(policy.topUpCount(remainingAhead: 0, pendingCount: 50) == 3)
    }

    @Test("the final top-up appends only what is left")
    func finalTopUpAppendsOnlyWhatIsLeft() {
        #expect(policy.topUpCount(remainingAhead: 0, pendingCount: 2) == 2)
        #expect(policy.topUpCount(remainingAhead: 0, pendingCount: 0) == 0)
    }

    @Test("a nearby requested track is reached rather than rebuilt around")
    func nearbyRequestedTrackIsReached() {
        // windowSize 5, so reach-ahead is capped at 5 by default.
        #expect(policy.reachAheadCount(toPendingIndex: 0) == 1)
        #expect(policy.reachAheadCount(toPendingIndex: 4) == 5)
    }

    @Test("a distant requested track falls back to replacing the queue")
    func distantRequestedTrackFallsBackToReplacement() {
        // Past the window a replacement starting at the track moves less data
        // than reaching it, so reaching stops being the better trade.
        #expect(policy.reachAheadCount(toPendingIndex: 5) == nil)
        #expect(policy.reachAheadCount(toPendingIndex: 500) == nil)
        #expect(policy.reachAheadCount(toPendingIndex: -1) == nil)
    }

    @Test("reach-ahead never hands over more than a fresh window would")
    func reachAheadNeverExceedsAWindow() {
        let shipped = PlaybackQueueWindowPolicy.standard
        let largest = (0..<5_000).compactMap(shipped.reachAheadCount(toPendingIndex:)).max() ?? 0
        #expect(largest <= shipped.windowSize)
    }

    @Test("the shipped policy caps hand-off well below a long playlist")
    func shippedPolicyCapsHandOff() {
        let split = PlaybackQueueWindowPolicy.standard.split(entryCount: 2_000, startIndex: 0)
        #expect(split.delivered.count == 50)
        #expect(split.pending.count == 1_950)
    }
}
