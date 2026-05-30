import MediaPlayer
@preconcurrency import MusicKit
import Testing
@testable import Overplay

struct RemotePlaybackModeMapperTests {
    @Test func mapsMusicRepeatModesToRemoteRepeatTypes() {
        #expect(RemotePlaybackModeMapper.repeatType(for: .none) == .off)
        #expect(RemotePlaybackModeMapper.repeatType(for: .one) == .one)
        #expect(RemotePlaybackModeMapper.repeatType(for: .all) == .all)
    }

    @Test func mapsRemoteRepeatTypesToMusicRepeatModes() {
        #expect(RemotePlaybackModeMapper.repeatMode(for: .off) == .none)
        #expect(RemotePlaybackModeMapper.repeatMode(for: .one) == .one)
        #expect(RemotePlaybackModeMapper.repeatMode(for: .all) == .all)
    }
}
