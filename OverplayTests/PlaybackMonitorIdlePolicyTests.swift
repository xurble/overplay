import MusicKit
import Testing
@testable import Overplay

@Suite("Playback monitor idle policy")
struct PlaybackMonitorIdlePolicyTests {
    @Test("moving playback keeps progress sampling", arguments: [MusicPlayer.PlaybackStatus.playing, .seekingForward, .seekingBackward])
    func movingPlaybackKeepsSampling(status: MusicPlayer.PlaybackStatus) {
        #expect(!PlaybackMonitorIdlePolicy.shouldSuspend(playbackStatus: status, isTransitionInFlight: false))
    }

    @Test("paused stopped and interrupted players suspend immediately", arguments: [MusicPlayer.PlaybackStatus.paused, .stopped, .interrupted])
    func idlePlaybackSuspends(status: MusicPlayer.PlaybackStatus) {
        #expect(PlaybackMonitorIdlePolicy.shouldSuspend(playbackStatus: status, isTransitionInFlight: false))
    }

    @Test("a pending transition retains sampling until it settles")
    func pendingTransitionRetainsSampling() {
        #expect(!PlaybackMonitorIdlePolicy.shouldSuspend(playbackStatus: .paused, isTransitionInFlight: true))
    }
}
