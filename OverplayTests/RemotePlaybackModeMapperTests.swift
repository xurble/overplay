import MediaPlayer
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
}
