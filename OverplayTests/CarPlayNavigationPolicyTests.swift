import Testing
@testable import Overplay

@Suite("CarPlay navigation policy")
struct CarPlayNavigationPolicyTests {
    @Test("the Overplay row shuffles when the One True Playlist is not live")
    func overplayRowShufflesWhenOneTruePlaylistIsNotLive() {
        #expect(CarPlayNavigationPolicy.overplayIntent(
            oneTruePlaylistMusicID: "otp",
            currentPlaylistID: nil,
            hasCurrentTrack: false,
            isPlaying: false
        ) == .shuffleAndPlay)

        #expect(CarPlayNavigationPolicy.overplayIntent(
            oneTruePlaylistMusicID: "otp",
            currentPlaylistID: "triage",
            hasCurrentTrack: true,
            isPlaying: true
        ) == .shuffleAndPlay)

        // A live playlist ID with no current track is not something to resume.
        #expect(CarPlayNavigationPolicy.overplayIntent(
            oneTruePlaylistMusicID: "otp",
            currentPlaylistID: "otp",
            hasCurrentTrack: false,
            isPlaying: false
        ) == .shuffleAndPlay)
    }

    @Test("the Overplay row never reshuffles the live One True Playlist")
    func overplayRowNeverReshufflesTheLiveOneTruePlaylist() {
        #expect(CarPlayNavigationPolicy.overplayIntent(
            oneTruePlaylistMusicID: "otp",
            currentPlaylistID: "otp",
            hasCurrentTrack: true,
            isPlaying: true
        ) == .showPlayer)

        // Paused resumes rather than losing the user's position.
        #expect(CarPlayNavigationPolicy.overplayIntent(
            oneTruePlaylistMusicID: "otp",
            currentPlaylistID: "otp",
            hasCurrentTrack: true,
            isPlaying: false
        ) == .resumeAndShowPlayer)
    }

    @Test("an unset One True Playlist has nothing to play")
    func unsetOneTruePlaylistHasNothingToPlay() {
        #expect(CarPlayNavigationPolicy.overplayIntent(
            oneTruePlaylistMusicID: nil,
            currentPlaylistID: nil,
            hasCurrentTrack: false,
            isPlaying: false
        ) == .shuffleAndPlay)
    }

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
