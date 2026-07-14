import Foundation
import Testing
@testable import Overplay

@Suite("Playback pending advance policy")
struct PlaybackPendingAdvancePolicyTests {
    private let startedAt = Date(timeIntervalSince1970: 1_000)

    @Test("confirmation of the pending track clears the pin")
    func confirmationOfThePendingTrackClearsThePin() {
        #expect(PlaybackPendingAdvancePolicy.resolution(
            pendingLocalTrackID: "pending",
            fromLocalTrackID: "from",
            confirmedLocalTrackID: "pending",
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(0.5)
        ) == .arrived)
    }

    @Test("the outgoing track keeps the pin while the skip propagates")
    func theOutgoingTrackKeepsThePinWhileTheSkipPropagates() {
        #expect(PlaybackPendingAdvancePolicy.resolution(
            pendingLocalTrackID: "pending",
            fromLocalTrackID: "from",
            confirmedLocalTrackID: "from",
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(0.5)
        ) == .propagating)
    }

    @Test("confirmation of any other track clears the pin")
    func confirmationOfAnyOtherTrackClearsThePin() {
        #expect(PlaybackPendingAdvancePolicy.resolution(
            pendingLocalTrackID: "pending",
            fromLocalTrackID: "from",
            confirmedLocalTrackID: "elsewhere",
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(0.5)
        ) == .diverged)
    }

    @Test("no confirmation keeps the pin until the timeout")
    func noConfirmationKeepsThePinUntilTheTimeout() {
        #expect(PlaybackPendingAdvancePolicy.resolution(
            pendingLocalTrackID: "pending",
            fromLocalTrackID: "from",
            confirmedLocalTrackID: nil,
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(1.9)
        ) == .pinned)
        #expect(PlaybackPendingAdvancePolicy.resolution(
            pendingLocalTrackID: "pending",
            fromLocalTrackID: "from",
            confirmedLocalTrackID: nil,
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(PlaybackPendingAdvancePolicy.timeoutSeconds)
        ) == .expired)
    }

    @Test("timeout wins over any confirmation")
    func timeoutWinsOverAnyConfirmation() {
        #expect(PlaybackPendingAdvancePolicy.resolution(
            pendingLocalTrackID: "pending",
            fromLocalTrackID: "from",
            confirmedLocalTrackID: "from",
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(3)
        ) == .expired)
    }

    @Test("a missing from-track treats the outgoing confirmation as divergence")
    func aMissingFromTrackTreatsTheOutgoingConfirmationAsDivergence() {
        #expect(PlaybackPendingAdvancePolicy.resolution(
            pendingLocalTrackID: "pending",
            fromLocalTrackID: nil,
            confirmedLocalTrackID: "from",
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(0.5)
        ) == .diverged)
    }
}
