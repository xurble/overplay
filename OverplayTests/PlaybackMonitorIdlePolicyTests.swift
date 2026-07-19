import Foundation
import Testing
@testable import Overplay

@Suite("Playback monitor idle policy")
struct PlaybackMonitorIdlePolicyTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("playing or stalled playback never accumulates idle time")
    func playingOrStalledPlaybackNeverAccumulatesIdleTime() {
        #expect(PlaybackMonitorIdlePolicy.updatedIdleStart(
            current: start,
            isPlaying: true,
            isDeliveryStalled: false,
            now: start.addingTimeInterval(10)
        ) == nil)
        #expect(PlaybackMonitorIdlePolicy.updatedIdleStart(
            current: start,
            isPlaying: false,
            isDeliveryStalled: true,
            now: start.addingTimeInterval(10)
        ) == nil)
    }

    @Test("idle time starts once and is preserved across ticks")
    func idleTimeStartsOnceAndIsPreservedAcrossTicks() {
        let began = PlaybackMonitorIdlePolicy.updatedIdleStart(
            current: nil,
            isPlaying: false,
            isDeliveryStalled: false,
            now: start
        )
        #expect(began == start)

        let continued = PlaybackMonitorIdlePolicy.updatedIdleStart(
            current: began,
            isPlaying: false,
            isDeliveryStalled: false,
            now: start.addingTimeInterval(60)
        )
        #expect(continued == start)
    }

    @Test("suspension requires the full idle timeout")
    func suspensionRequiresTheFullIdleTimeout() {
        #expect(!PlaybackMonitorIdlePolicy.shouldSuspend(idleSince: nil, now: start))
        #expect(!PlaybackMonitorIdlePolicy.shouldSuspend(
            idleSince: start,
            now: start.addingTimeInterval(PlaybackMonitorIdlePolicy.idleTimeoutSeconds - 1)
        ))
        #expect(PlaybackMonitorIdlePolicy.shouldSuspend(
            idleSince: start,
            now: start.addingTimeInterval(PlaybackMonitorIdlePolicy.idleTimeoutSeconds)
        ))
    }
}
