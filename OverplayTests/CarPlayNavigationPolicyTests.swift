import Testing
@testable import Overplay

@Suite("CarPlay navigation policy")
struct CarPlayNavigationPolicyTests {
    @Test("track rows jump inside the live queue and never restart the live track")
    func trackRowsJumpInsideTheLiveQueue() {
        #expect(CarPlayNavigationPolicy.trackIntent(
            isCurrentTrack: true,
            isInLiveQueue: true
        ) == .showPlayer)

        #expect(CarPlayNavigationPolicy.trackIntent(
            isCurrentTrack: false,
            isInLiveQueue: true
        ) == .skipInLiveQueue)

        #expect(CarPlayNavigationPolicy.trackIntent(
            isCurrentTrack: false,
            isInLiveQueue: false
        ) == .startPlaylist)
    }
}
