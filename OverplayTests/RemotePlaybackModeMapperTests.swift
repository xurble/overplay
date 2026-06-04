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

    @Test func mapsRepeatEnabledToRemoteRepeatTypes() {
        #expect(RemotePlaybackModeMapper.repeatType(for: false) == .off)
        #expect(RemotePlaybackModeMapper.repeatType(for: true) == .all)
    }

    @Test func mapsRemoteRepeatTypesToRepeatEnabled() {
        #expect(!RemotePlaybackModeMapper.repeatEnabled(for: .off))
        #expect(RemotePlaybackModeMapper.repeatEnabled(for: .all))
        #expect(RemotePlaybackModeMapper.repeatEnabled(for: .one))
    }

    @Test func mapsMusicRepeatModesToRemoteRepeatTypes() {
        #expect(RemotePlaybackModeMapper.repeatType(for: .none) == .off)
        #expect(RemotePlaybackModeMapper.repeatType(for: .one) == .off)
        #expect(RemotePlaybackModeMapper.repeatType(for: .all) == .all)
    }

    @Test func mapsRemoteRepeatTypesToMusicRepeatModes() {
        #expect(RemotePlaybackModeMapper.repeatMode(for: .off) == .none)
        #expect(RemotePlaybackModeMapper.repeatMode(for: .one) == .none)
        #expect(RemotePlaybackModeMapper.repeatMode(for: .all) == .all)
    }
}
