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

    @Test("the shipped policy caps hand-off well below a long playlist")
    func shippedPolicyCapsHandOff() {
        let split = PlaybackQueueWindowPolicy.standard.split(entryCount: 2_000, startIndex: 0)
        #expect(split.delivered.count == 50)
        #expect(split.pending.count == 1_950)
    }
}
