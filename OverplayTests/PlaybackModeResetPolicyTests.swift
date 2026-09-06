import Foundation
@preconcurrency import MusicKit
import Testing
@testable import Overplay

@Suite("MusicKit playback mode writes")
struct PlaybackModeResetPolicyTests {
    // `MusicPlayer.RepeatMode.none` is always written out here. A bare `.none`
    // against these optional parameters silently means `Optional.none`, which
    // is a different case and makes the assertion test nothing it claims to.
    private let repeatOff = MusicPlayer.RepeatMode.none

    @Test("modes already off need no write")
    func modesAlreadyOffNeedNoWrite() {
        #expect(!PlaybackModeResetPolicy.needsReset(shuffleMode: .off, repeatMode: repeatOff))
    }

    @Test("either mode being on needs the write")
    func eitherModeBeingOnNeedsTheWrite() {
        #expect(PlaybackModeResetPolicy.needsReset(shuffleMode: .songs, repeatMode: repeatOff))
        #expect(PlaybackModeResetPolicy.needsReset(shuffleMode: .off, repeatMode: .all))
        #expect(PlaybackModeResetPolicy.needsReset(shuffleMode: .off, repeatMode: .one))
        #expect(PlaybackModeResetPolicy.needsReset(shuffleMode: .songs, repeatMode: .all))
    }

    @Test("an unreported mode is written rather than assumed off")
    func unreportedModeIsWrittenRatherThanAssumedOff() {
        // Guessing "already off" here would leave shuffle applied over
        // Overplay's own playback order.
        #expect(PlaybackModeResetPolicy.needsReset(shuffleMode: nil, repeatMode: repeatOff))
        #expect(PlaybackModeResetPolicy.needsReset(shuffleMode: .off, repeatMode: nil))
        #expect(PlaybackModeResetPolicy.needsReset(shuffleMode: nil, repeatMode: nil))
    }
}
