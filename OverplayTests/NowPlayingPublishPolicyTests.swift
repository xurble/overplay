import Foundation
import Testing
@testable import Overplay

@Suite("Now Playing publish policy")
struct NowPlayingPublishPolicyTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Owning the session

    @Test("nothing is published while the shared player holds none of our entries")
    func nothingIsPublishedWhileTheSharedPlayerHoldsNoneOfOurEntries() {
        // The launch case: a restored display track, no player queue. Writing
        // here would take the Now Playing session from whatever is playing.
        let decision = NowPlayingPublishPolicy.decision(
            identity: identity(),
            elapsedSeconds: 12,
            ownsPlayback: false,
            lastPublished: nil,
            now: Self.now
        )

        #expect(decision == .skip)
    }

    @Test("losing the player retracts only a session we published")
    func losingThePlayerRetractsOnlyASessionWePublished() {
        let decision = NowPlayingPublishPolicy.decision(
            identity: nil,
            elapsedSeconds: 0,
            ownsPlayback: false,
            lastPublished: published(elapsedSeconds: 30, secondsAgo: 1),
            now: Self.now
        )

        #expect(decision == .clear)
    }

    @Test("owning the player with no describable track keeps the last payload")
    func owningThePlayerWithNoDescribableTrackKeepsTheLastPayload() {
        // Mid-transition the display track can be briefly nil. Flapping the
        // session to empty and back is worse than holding the last payload.
        let decision = NowPlayingPublishPolicy.decision(
            identity: nil,
            elapsedSeconds: 0,
            ownsPlayback: true,
            lastPublished: published(elapsedSeconds: 30, secondsAgo: 1),
            now: Self.now
        )

        #expect(decision == .skip)
    }

    // MARK: - Change detection

    @Test("the first publish for a track always happens")
    func theFirstPublishForATrackAlwaysHappens() {
        let decision = NowPlayingPublishPolicy.decision(
            identity: identity(),
            elapsedSeconds: 0,
            ownsPlayback: true,
            lastPublished: nil,
            now: Self.now
        )

        #expect(decision == .publish)
    }

    @Test("a track change publishes")
    func aTrackChangePublishes() {
        let decision = NowPlayingPublishPolicy.decision(
            identity: identity(title: "Second"),
            elapsedSeconds: 0,
            ownsPlayback: true,
            lastPublished: published(elapsedSeconds: 200, secondsAgo: 1),
            now: Self.now
        )

        #expect(decision == .publish)
    }

    @Test("a play state change publishes")
    func aPlayStateChangePublishes() {
        let decision = NowPlayingPublishPolicy.decision(
            identity: identity(isPlaying: false),
            elapsedSeconds: 31,
            ownsPlayback: true,
            lastPublished: published(elapsedSeconds: 30, secondsAgo: 1),
            now: Self.now
        )

        #expect(decision == .publish)
    }

    @Test("steady playback is skipped because the system extrapolates position")
    func steadyPlaybackIsSkippedBecauseTheSystemExtrapolatesPosition() {
        // Ten 1 Hz ticks after a publish at 30s: the position advanced
        // exactly as the system already believes, so no write is needed.
        for tick in 1...10 {
            let decision = NowPlayingPublishPolicy.decision(
                identity: identity(),
                elapsedSeconds: 30 + Double(tick),
                ownsPlayback: true,
                lastPublished: published(elapsedSeconds: 30, secondsAgo: Double(tick)),
                now: Self.now
            )
            #expect(decision == .skip, "tick \(tick)")
        }
    }

    @Test("a paused position holding still is skipped")
    func aPausedPositionHoldingStillIsSkipped() {
        let decision = NowPlayingPublishPolicy.decision(
            identity: identity(isPlaying: false),
            elapsedSeconds: 30,
            ownsPlayback: true,
            lastPublished: published(elapsedSeconds: 30, isPlaying: false, secondsAgo: 10),
            now: Self.now
        )

        #expect(decision == .skip)
    }

    @Test("a seek beyond the drift tolerance publishes")
    func aSeekBeyondTheDriftTolerancePublishes() {
        let drift = NowPlayingPublishPolicy.elapsedDriftTolerance + 1
        let decision = NowPlayingPublishPolicy.decision(
            identity: identity(),
            elapsedSeconds: 30 + 5 + drift,
            ownsPlayback: true,
            lastPublished: published(elapsedSeconds: 30, secondsAgo: 5),
            now: Self.now
        )

        #expect(decision == .publish)
    }

    @Test("a backwards seek beyond the drift tolerance publishes")
    func aBackwardsSeekBeyondTheDriftTolerancePublishes() {
        let decision = NowPlayingPublishPolicy.decision(
            identity: identity(),
            elapsedSeconds: 2,
            ownsPlayback: true,
            lastPublished: published(elapsedSeconds: 120, secondsAgo: 1),
            now: Self.now
        )

        #expect(decision == .publish)
    }

    @Test("a stalled position publishes once the drift exceeds the tolerance")
    func aStalledPositionPublishesOnceTheDriftExceedsTheTolerance() {
        // Player claims to be playing but the position is frozen: the system's
        // extrapolated position runs away, so it must be corrected.
        let secondsFrozen = NowPlayingPublishPolicy.elapsedDriftTolerance + 1
        let decision = NowPlayingPublishPolicy.decision(
            identity: identity(),
            elapsedSeconds: 30,
            ownsPlayback: true,
            lastPublished: published(elapsedSeconds: 30, secondsAgo: secondsFrozen),
            now: Self.now
        )

        #expect(decision == .publish)
    }

    @Test("the heartbeat re-anchors long, steady playback")
    func theHeartbeatReAnchorsLongSteadyPlayback() {
        let interval = NowPlayingPublishPolicy.reanchorInterval
        let decision = NowPlayingPublishPolicy.decision(
            identity: identity(),
            elapsedSeconds: 30 + interval,
            ownsPlayback: true,
            lastPublished: published(elapsedSeconds: 30, secondsAgo: interval),
            now: Self.now
        )

        #expect(decision == .publish)
    }

    @Test("a whole track of 1 Hz ticks costs only a handful of writes")
    func aWholeTrackOf1HzTicksCostsOnlyAHandfulOfWrites() {
        // The reduction this policy exists for: 240 ticks used to be 240
        // writes to the system Now Playing session.
        var lastPublished: NowPlayingPublishPolicy.Published?
        var publishCount = 0
        let trackSeconds = 240

        for tick in 0...trackSeconds {
            let tickDate = Self.now.addingTimeInterval(Double(tick))
            let elapsed = Double(tick)
            let decision = NowPlayingPublishPolicy.decision(
                identity: identity(),
                elapsedSeconds: elapsed,
                ownsPlayback: true,
                lastPublished: lastPublished,
                now: tickDate
            )
            if decision == .publish {
                publishCount += 1
                lastPublished = NowPlayingPublishPolicy.Published(
                    identity: identity(),
                    elapsedSeconds: elapsed,
                    publishedAt: tickDate
                )
            }
        }

        // One initial publish plus one heartbeat per re-anchor interval.
        let expected = 1 + trackSeconds / Int(NowPlayingPublishPolicy.reanchorInterval)
        #expect(publishCount == expected)
        #expect(publishCount <= 5)
    }

    // MARK: - Fixtures

    private func identity(
        title: String = "First",
        isPlaying: Bool = true
    ) -> NowPlayingPublishPolicy.Identity {
        NowPlayingPublishPolicy.Identity(
            title: title,
            artistName: "Artist",
            albumTitle: "Album",
            durationSeconds: 240,
            isPlaying: isPlaying
        )
    }

    private func published(
        elapsedSeconds: Double,
        isPlaying: Bool = true,
        secondsAgo: Double
    ) -> NowPlayingPublishPolicy.Published {
        NowPlayingPublishPolicy.Published(
            identity: identity(isPlaying: isPlaying),
            elapsedSeconds: elapsedSeconds,
            publishedAt: Self.now.addingTimeInterval(-secondsAgo)
        )
    }
}
