import MediaPlayer
@preconcurrency import MusicKit
import Testing
@testable import Overplay

struct RemotePlaybackModeMapperTests {
    @Test func mapsShuffleEnabledToRemoteShuffleTypes() {
        #expect(RemotePlaybackModeMapper.shuffleType(for: false) == .off)
        #expect(RemotePlaybackModeMapper.shuffleType(for: true) == .items)
    }

    @Test func mapsRemoteShuffleTypesToShuffleEnabled() {
        #expect(!RemotePlaybackModeMapper.shuffleEnabled(for: .off))
        #expect(RemotePlaybackModeMapper.shuffleEnabled(for: .items))
        #expect(RemotePlaybackModeMapper.shuffleEnabled(for: .collections))
    }

    @Test func canonicalizesRemoteShuffleTypesToSupportedStates() {
        #expect(RemotePlaybackModeMapper.canonicalShuffleType(for: .off) == .off)
        #expect(RemotePlaybackModeMapper.canonicalShuffleType(for: .items) == .items)
        #expect(RemotePlaybackModeMapper.canonicalShuffleType(for: .collections) == .items)
    }

    @Test("repeat round-trips every mode")
    func repeatRoundTripsEveryMode() {
        // A remote "repeat off" arriving as anything else is how a system
        // control ends up fighting the app over the mode.
        for mode in [MusicPlayer.RepeatMode.none, .all, .one] {
            let type = RemotePlaybackModeMapper.repeatType(for: mode)
            #expect(RemotePlaybackModeMapper.repeatMode(for: type) == mode)
        }

        #expect(RemotePlaybackModeMapper.repeatType(for: MusicPlayer.RepeatMode.none) == .off)
        #expect(RemotePlaybackModeMapper.repeatType(for: .all) == .all)
        #expect(RemotePlaybackModeMapper.repeatType(for: .one) == .one)
    }
}
