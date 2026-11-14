import Foundation
import SwiftData
import Testing
@testable import Overplay

/// Siri's actions (`SIRI-001`) through the shared entry points the app and
/// CarPlay use, Shuffle and Play resuming the current playlist (`PLAY-020`),
/// Promote keeping the song playing (`MUT-004`),
/// and undoing the last promote or retire (`MUT-003`).
@MainActor
@Suite("Voice actions and undo", .serialized)
struct VoiceActionTests {
    // MARK: - Library wait for a launch with no window (`SIRI-002`)

    private let authorized = AppleMusicReadiness.authorized(canPlayCatalogContent: true, hasCloudLibraryEnabled: true)

    private func wait(
        attempts: Int = 80, states: [VoiceActions.LibraryState]
    ) async -> (state: VoiceActions.LibraryState, pauses: Int) {
        var remaining = states[...]
        var pauses = 0
        let state = await VoiceActions.awaitLibrary(
            attempts: attempts,
            state: { remaining.count > 1 ? remaining.removeFirst() : remaining[remaining.startIndex] },
            pause: { pauses += 1 }
        )
        return (state, pauses)
    }

    private func state(
        isLibraryReady: Bool = false, readiness: AppleMusicReadiness? = nil, isSettingUp: Bool = false,
        preparationFailed: Bool = false
    ) -> VoiceActions.LibraryState {
        VoiceActions.libraryState(isLibraryReady: isLibraryReady, readiness: readiness ?? authorized,
                                  isSettingUp: isSettingUp, preparationFailed: preparationFailed)
    }

    @Test func everyUnauthorisedStateStopsTheWaitAtOnceWithItsOwnMessage() async {
        let unauthorised: [AppleMusicReadiness] = [
            .notDetermined, .denied, .restricted, .failed("offline"),
            .authorized(canPlayCatalogContent: false, hasCloudLibraryEnabled: true),
            .authorized(canPlayCatalogContent: true, hasCloudLibraryEnabled: false),
        ]
        for readiness in unauthorised {
            let result = await wait(states: [state(readiness: readiness)])

            #expect(result.state == .notAuthorized, "\(readiness)")
            #expect(result.pauses == 0, "\(readiness)")
            #expect(VoiceActions.spokenReason(for: result.state) == VoiceActions.notAuthorizedMessage)
        }
    }

    @Test func unfinishedSetupStopsTheWaitAtOnceWithItsOwnMessage() async {
        let result = await wait(states: [state(isSettingUp: true)])

        #expect(result.state == .setupUnfinished)
        #expect(result.pauses == 0)
        #expect(VoiceActions.spokenReason(for: result.state) == VoiceActions.setupUnfinishedMessage)
    }

    @Test func setupFoundDuringTheWaitStopsItOnTheNextLook() async {
        let result = await wait(states: [state(), state(isSettingUp: true)])

        #expect(result.state == .setupUnfinished)
        #expect(result.pauses == 1)
    }

    @Test func aPreparationErrorStopsTheWaitAsItAlwaysDid() async {
        let result = await wait(states: [state(preparationFailed: true)])

        #expect(result.state == .preparationFailed)
        #expect(result.pauses == 0)
        #expect(VoiceActions.spokenReason(for: result.state) == VoiceActions.notReadyMessage)
    }

    @Test func realRestorationIsWaitedForUpToTheLimitThenSaysSo() async {
        let result = await wait(attempts: 80, states: [state()])

        #expect(result.state == .restoring)
        #expect(result.pauses == 80)
        #expect(VoiceActions.spokenReason(for: result.state) == VoiceActions.notReadyMessage)
    }

    @Test func aRestorationThatFinishesDuringTheWaitIsReady() async {
        let result = await wait(states: [state(), state(), state(isLibraryReady: true)])

        #expect(result.state == .ready)
        #expect(result.pauses == 2)
        #expect(VoiceActions.spokenReason(for: result.state) == nil)
    }

    @Test func aReadyLibraryIsReadyWhateverElseIsTrue() {
        #expect(state(isLibraryReady: true, readiness: .denied, isSettingUp: true) == .ready)
    }

    // MARK: - Shuffle and Play resumes the current playlist (`PLAY-020`)

    @Test func shuffleAndPlayResumesThePausedPlaylistInsteadOfRestarting() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, settings: fixture.settings, context: fixture.context)
        let current = fixture.controller.currentTrack?.title
        fixture.controller.pause()

        await fixture.controller.playPlaylist(fixture.playlist, settings: fixture.settings, context: fixture.context)

        #expect(fixture.player.submitCount == 1)
        #expect(fixture.player.commands.last == "play")
        #expect(fixture.controller.currentTrack?.title == current)
        #expect(fixture.controller.isPlaying)
    }

    @Test func shuffleAndPlayLeavesThePlayingPlaylistAlone() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, settings: fixture.settings, context: fixture.context)
        let commands = fixture.player.commands

        await fixture.controller.playPlaylist(fixture.playlist, settings: fixture.settings, context: fixture.context)

        #expect(fixture.player.commands == commands)
        #expect(fixture.player.submitCount == 1)
    }

    @Test func shuffleAndPlayShufflesThePlayingPlaylistWithoutRestartingIt() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        await play(fixture, startingAt: 1)
        #expect(!fixture.controller.shuffleEnabled)
        let before = fixture.player.commands.count

        await fixture.controller.playPlaylist(fixture.playlist, settings: fixture.settings, context: fixture.context)

        #expect(Array(fixture.player.commands.dropFirst(before)) == ["shuffle=songs"])
        #expect(fixture.controller.shuffleEnabled)
        #expect(fixture.player.submitCount == 1)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
    }

    @Test func shuffleAndPlayOfThePausedUnshuffledPlaylistShufflesAndThenPlays() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        await play(fixture, startingAt: 1)
        fixture.controller.pause()
        let before = fixture.player.commands.count

        await fixture.controller.playPlaylist(fixture.playlist, settings: fixture.settings, context: fixture.context)

        #expect(Array(fixture.player.commands.dropFirst(before)) == ["shuffle=songs", "play"])
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        #expect(fixture.controller.isPlaying)
    }

    @Test func shuffleAndPlayOfAnotherScopeStartsFresh() async throws {
        let fixture = try PlaybackFixture(role: .triageBucket); defer { fixture.cleanUp() }
        try fixture.item(2).evictedAt = .now
        try fixture.context.save()
        await fixture.controller.playPlaylist(fixture.playlist, settings: fixture.settings, context: fixture.context)

        await fixture.controller.playPlaylist(fixture.playlist, scope: .retired, settings: fixture.settings,
                                              context: fixture.context)

        #expect(fixture.player.submitCount == 2)
        #expect(fixture.controller.currentPlaylistContext == fixture.playlist.playbackContext(.retired))
    }

    // MARK: - Play by voice (`SIRI-001`)

    @Test func playingTheOneTruePlaylistByVoiceUsesTheSharedStartAndThenCarriesOn() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }

        let first = await VoiceActions.play(.oneTruePlaylist, controller: fixture.controller, context: fixture.context)
        let second = await VoiceActions.play(.oneTruePlaylist, controller: fixture.controller, context: fixture.context)

        #expect(first == nil && second == nil)
        #expect(fixture.controller.currentPlaylistContext == fixture.playlist.playbackContext())
        #expect(fixture.player.submitCount == 1)
    }

    @Test func playingTriageByVoicePlaysTheBucket() async throws {
        let fixture = try PlaybackFixture(role: .triageBucket); defer { fixture.cleanUp() }

        let failure = await VoiceActions.play(.triage, controller: fixture.controller, context: fixture.context)

        #expect(failure == nil)
        #expect(fixture.controller.currentPlaylistContext == fixture.playlist.playbackContext(.active))
    }

    @Test func playingWithoutAOneTruePlaylistSaysWhyAndPlaysNothing() async throws {
        let fixture = try PlaybackFixture(role: .triageBucket); defer { fixture.cleanUp() }

        let failure = await VoiceActions.play(.oneTruePlaylist, controller: fixture.controller, context: fixture.context)

        #expect(failure == "Choose a One True Playlist in Overplay first.")
        #expect(fixture.player.submitCount == 0)
    }

    // MARK: - Promote and retire by voice

    @Test func curationWithNothingPlayingSaysSo() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }

        let outcome = await VoiceActions.curate(.promote, controller: fixture.controller, context: fixture.context)

        #expect(outcome == .unavailable("Nothing from Overplay is playing."))
    }

    @Test func promotingASongAlreadyInTheOneTruePlaylistSaysSo() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        await play(fixture, startingAt: 0)

        let outcome = await VoiceActions.curate(.promote, controller: fixture.controller, context: fixture.context)

        #expect(outcome == .unavailable("Song 0 is already in your One True Playlist."))
        #expect(try fixture.item(0).playlistID == fixture.playlist.id)
    }

    // MARK: - Promote keeps playing (`MUT-004`)

    @Test func promotingTheCurrentTriageSongKeepsItPlayingAndCounting() async throws {
        let fixture = try PlaybackFixture(role: .triageBucket); defer { fixture.cleanUp() }
        let otp = try addOneTruePlaylist(to: fixture)
        stubAppleMusic(fixture)
        await play(fixture, startingAt: 0)
        let commands = fixture.player.commands

        let promoted = await VoiceActions.curate(.promote, controller: fixture.controller, context: fixture.context)

        #expect(promoted == .moved(title: "Song 0", to: .oneTruePlaylist))
        #expect(fixture.player.commands == commands)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        #expect(fixture.controller.currentPlaylistRole(context: fixture.context) == .oneTruePlaylist)
        await fixture.listen(to: 170)
        let item = try fixture.item(0)
        #expect(item.playlistID == otp.id)
        #expect(item.playthroughCount == 1)
    }

    @Test func promotingATriageSongInAnAlbumKeepsItPlaying() async throws {
        let fixture = try PlaybackFixture(role: .triageBucket); defer { fixture.cleanUp() }
        let otp = try addOneTruePlaylist(to: fixture)
        stubAppleMusic(fixture)
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try FakePlaybackCatalog.album()
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        await play(fixture, startingAt: 1)
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        let commands = fixture.player.commands

        await fixture.controller.promoteCurrent(settings: fixture.settings, context: fixture.context)

        #expect(fixture.player.commands == commands)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        #expect(try fixture.item(0).playlistID == otp.id)
    }

    @Test func retiringAnAlreadyRetiredSongChangesNothing() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        stubAppleMusic(fixture)
        try fixture.controller.retireTrack(try fixture.item(0), playlist: fixture.playlist, message: "Retired",
                                           context: fixture.context)
        let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
        await fixture.controller.playPlaylist(bucket, startingAt: fixture.tracks[0], scope: .retired,
                                              settings: fixture.settings, context: fixture.context)
        let commands = fixture.player.commands

        let outcome = await VoiceActions.curate(.retire, controller: fixture.controller, context: fixture.context)

        #expect(outcome == .unavailable("Song 0 is already retired."))
        #expect(fixture.player.commands == commands)
    }

    // MARK: - Undo (`MUT-003`)

    @Test func undoingAOneTruePlaylistRetirePutsTheSongBackWithoutTouchingPlayback() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        stubAppleMusic(fixture)
        try keep(0, in: fixture)
        await play(fixture, startingAt: 0)

        let retired = await VoiceActions.curate(.retire, controller: fixture.controller, context: fixture.context)
        #expect(retired == .moved(title: "Song 0", to: .retired))
        #expect(try fixture.item(0).evictedAt != nil)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        let commands = fixture.player.commands

        let undone = await VoiceActions.curate(.undo, controller: fixture.controller, context: fixture.context)

        #expect(undone == .moved(title: "Song 0", to: .oneTruePlaylist))
        let item = try fixture.item(0)
        #expect(item.playlistID == fixture.playlist.id && item.evictedAt == nil)
        #expect(fixture.player.commands == commands)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
    }

    @Test func undoIsOneLevel() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        stubAppleMusic(fixture)
        try keep(0, in: fixture)
        await play(fixture, startingAt: 0)
        _ = await VoiceActions.curate(.retire, controller: fixture.controller, context: fixture.context)
        _ = await VoiceActions.curate(.undo, controller: fixture.controller, context: fixture.context)

        let again = await VoiceActions.curate(.undo, controller: fixture.controller, context: fixture.context)

        #expect(again == .unavailable("There's nothing to undo."))
        #expect(try fixture.item(0).evictedAt == nil)
    }

    @Test func undoCoversARetireFromAPlaylistRow() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        stubAppleMusic(fixture)
        try keep(2, in: fixture)
        try fixture.controller.retireTrack(try fixture.item(2), playlist: fixture.playlist, message: "Retired",
                                           context: fixture.context)

        let undone = await VoiceActions.curate(.undo, controller: fixture.controller, context: fixture.context)

        #expect(undone == .moved(title: "Song 2", to: .oneTruePlaylist))
        #expect(try fixture.item(2).evictedAt == nil)
    }

    @Test func undoingATriageRetireReturnsTheSongToTriageAsItWas() async throws {
        let fixture = try PlaybackFixture(role: .triageBucket); defer { fixture.cleanUp() }
        try keep(0, in: fixture)
        await play(fixture, startingAt: 0)
        _ = await VoiceActions.curate(.retire, controller: fixture.controller, context: fixture.context)

        let undone = await VoiceActions.curate(.undo, controller: fixture.controller, context: fixture.context)

        #expect(undone == .moved(title: "Song 0", to: .triage))
        let item = try fixture.item(0)
        #expect(item.playlistID == fixture.playlist.id && item.evictedAt == nil)
        #expect(!item.isExplicitlyKept)
    }

    @Test func undoingAPromotionReturnsTheSongToTriageAndKeepsSyncFromPromotingItAgain() async throws {
        let fixture = try PlaybackFixture(role: .triageBucket); defer { fixture.cleanUp() }
        let otp = try addOneTruePlaylist(to: fixture)
        stubAppleMusic(fixture, cloudHolds: ["i.lib-0"])
        await play(fixture, startingAt: 0)

        let promoted = await VoiceActions.curate(.promote, controller: fixture.controller, context: fixture.context)
        #expect(promoted == .moved(title: "Song 0", to: .oneTruePlaylist))
        #expect(try fixture.item(0).playlistID == otp.id)

        let undone = await VoiceActions.curate(.undo, controller: fixture.controller, context: fixture.context)

        #expect(undone == .moved(title: "Song 0", to: .triage))
        let item = try fixture.item(0)
        #expect(item.playlistID == fixture.playlist.id && item.evictedAt == nil)
        #expect(item.suppressedOTPMusicPlaylistIDs.contains(otp.musicPlaylistID))
    }

    @Test func undoingAPromotionFromRetiredRetiresTheSongAgain() async throws {
        let fixture = try PlaybackFixture(role: .triageBucket); defer { fixture.cleanUp() }
        _ = try addOneTruePlaylist(to: fixture)
        stubAppleMusic(fixture)
        try keep(0, in: fixture)
        try fixture.item(0).evictedAt = .now
        try fixture.context.save()
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0], scope: .retired,
                                              settings: fixture.settings, context: fixture.context)
        _ = await VoiceActions.curate(.promote, controller: fixture.controller, context: fixture.context)

        let undone = await VoiceActions.curate(.undo, controller: fixture.controller, context: fixture.context)

        #expect(undone == .moved(title: "Song 0", to: .retired))
        let item = try fixture.item(0)
        #expect(item.playlistID == fixture.playlist.id && item.evictedAt != nil)
    }

    @Test func undoEndsAfterTenMinutes() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        stubAppleMusic(fixture)
        try keep(0, in: fixture)
        await play(fixture, startingAt: 0)
        _ = await VoiceActions.curate(.retire, controller: fixture.controller, context: fixture.context)

        let late = await fixture.controller.undoLastCuration(context: fixture.context, now: .now.addingTimeInterval(11 * 60))

        #expect(late == .unavailable("It's too late to undo retiring Song 0."))
        #expect(try fixture.item(0).evictedAt != nil)
    }

    @Test func undoEndsWhenTheSongHasMovedSince() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        stubAppleMusic(fixture)
        try keep(0, in: fixture)
        await play(fixture, startingAt: 0)
        _ = await VoiceActions.curate(.retire, controller: fixture.controller, context: fixture.context)
        try fixture.controller.restoreTrack(try fixture.item(0), playlist: nil, context: fixture.context)

        let undone = await VoiceActions.curate(.undo, controller: fixture.controller, context: fixture.context)

        #expect(undone == .unavailable("Song 0 has moved since, so there's nothing to undo."))
        let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
        #expect(try fixture.item(0).playlistID == bucket.id)
    }

    // MARK: - Restore by voice

    @Test func restoringTheRetiredCurrentSongByVoiceMovesItToTheInboxWithoutTouchingPlayback() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        stubAppleMusic(fixture)
        try keep(0, in: fixture)
        try fixture.controller.retireTrack(try fixture.item(0), playlist: fixture.playlist, message: "Retired",
                                           context: fixture.context)
        let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
        await fixture.controller.playPlaylist(bucket, startingAt: fixture.tracks[0], scope: .retired,
                                              settings: fixture.settings, context: fixture.context)
        let commands = fixture.player.commands

        let outcome = await VoiceActions.curate(.restore, controller: fixture.controller, context: fixture.context)

        #expect(outcome == .moved(title: "Song 0", to: .triage))
        let item = try fixture.item(0)
        #expect(item.evictedAt == nil && item.playlistID == bucket.id)
        #expect(fixture.player.commands == commands)
    }

    /// The app and CarPlay offer Restore only on a retired song; Siri can ask
    /// for any, and the shared action refuses the rest.
    @Test func restoringASongThatIsNotRetiredChangesNothing() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        await play(fixture, startingAt: 0)

        let outcome = await VoiceActions.curate(.restore, controller: fixture.controller, context: fixture.context)

        #expect(outcome == .unavailable("Song 0 isn't retired."))
        let item = try fixture.item(0)
        #expect(item.playlistID == fixture.playlist.id && item.evictedAt == nil)
    }

    @Test func restoringWithNothingPlayingSaysSo() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }

        let outcome = await VoiceActions.curate(.restore, controller: fixture.controller, context: fixture.context)

        #expect(outcome == .unavailable("Nothing from Overplay is playing."))
    }

    // MARK: - Add by voice

    @Test func addingTheUntrackedAlbumSongByVoiceAddsItToTheInbox() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        try await playUntrackedAlbumSong(fixture)
        let commands = fixture.player.commands

        let outcome = await VoiceActions.curate(.add, controller: fixture.controller, context: fixture.context)

        #expect(outcome == .added(title: "Album Song 1"))
        #expect(outcome.message == "Added Album Song 1 to the Inbox.")
        #expect(!fixture.controller.canAddCurrentToOverplay)
        let trackID = try #require(fixture.controller.currentMember?.trackID)
        let bucket = try PlaylistRepository.triageBucket(in: fixture.context)
        #expect(try PlaylistItemRepository.item(trackID: trackID, in: fixture.context)?.playlistID == bucket.id)
        #expect(fixture.player.commands == commands)
    }

    @Test func addingASongOverplayAlreadyTracksSaysSo() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        await play(fixture, startingAt: 0)

        let outcome = await VoiceActions.curate(.add, controller: fixture.controller, context: fixture.context)

        #expect(outcome == .unavailable("Song 0 is already in Overplay."))
    }

    @Test func addingWithNothingPlayingSaysSo() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }

        let outcome = await VoiceActions.curate(.add, controller: fixture.controller, context: fixture.context)

        #expect(outcome == .unavailable("Nothing is playing."))
    }

    // MARK: - Play this album or artist by voice (`PLAY-018`)

    @Test func playingThisAlbumByVoiceStartsItThroughTheSharedAction() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let catalog = try albumCatalog(fixture)
        await play(fixture, startingAt: 0)

        let failure = await VoiceActions.diveDeeper(.album, controller: fixture.controller, context: fixture.context)

        #expect(failure == nil)
        #expect(catalog.requests.map(\.0) == [.album])
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        #expect(fixture.controller.canAddCurrentToOverplay == false)
        #expect(fixture.player.submitCount == 2)
    }

    @Test func playingThisAlbumWithNothingPlayingSaysSoAndLooksNothingUp() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let catalog = try albumCatalog(fixture)

        let failure = await VoiceActions.diveDeeper(.album, controller: fixture.controller, context: fixture.context)

        #expect(failure == "Nothing is playing.")
        #expect(catalog.requests.isEmpty)
    }

    @Test func aFailedAlbumLookupByVoiceSaysWhyAndKeepsPlaying() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        let catalog = try albumCatalog(fixture)
        catalog.failure = URLError(.notConnectedToInternet)
        await play(fixture, startingAt: 1)

        let failure = await VoiceActions.diveDeeper(.album, controller: fixture.controller, context: fixture.context)

        #expect(failure != nil)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        #expect(fixture.player.submitCount == 1)
    }

    // MARK: - What's this (`SIRI-001`)

    @Test func whatsThisSaysTheSongWhereItIsAndItsCounts() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        try fixture.item(0).playthroughCount = 3
        try fixture.item(0).skipCount = 1
        try fixture.context.save()
        await play(fixture, startingAt: 0)
        let commands = fixture.player.commands

        let said = VoiceActions.describeCurrent(controller: fixture.controller, context: fixture.context)

        #expect(said == "This is Song 0 by Artist 0. It's in your One True Playlist. "
            + "You've played it 3 times and skipped it once.")
        #expect(fixture.player.commands == commands)
    }

    @Test func whatsThisNamesTheInboxAndRetired() async throws {
        let fixture = try PlaybackFixture(role: .triageBucket); defer { fixture.cleanUp() }
        await play(fixture, startingAt: 0)
        #expect(VoiceActions.describeCurrent(controller: fixture.controller, context: fixture.context)
            == "This is Song 0 by Artist 0. It's in the Inbox. You haven't played or skipped it yet.")

        try fixture.item(1).evictedAt = .now
        try fixture.context.save()
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1], scope: .retired,
                                              settings: fixture.settings, context: fixture.context)
        #expect(VoiceActions.describeCurrent(controller: fixture.controller, context: fixture.context)
            == "This is Song 1 by Artist 1. It's retired. You haven't played or skipped it yet.")
    }

    @Test func whatsThisSaysWhenASongIsNotInOverplayOrNothingPlays() async throws {
        let fixture = try PlaybackFixture(); defer { fixture.cleanUp() }
        #expect(VoiceActions.describeCurrent(controller: fixture.controller, context: fixture.context)
            == "Nothing is playing.")

        try await playUntrackedAlbumSong(fixture)

        #expect(VoiceActions.describeCurrent(controller: fixture.controller, context: fixture.context)
            == "This is Album Song 1 by Artist 0. It isn't in Overplay.")
    }

    @Test func countsAreSpokenNaturally() {
        #expect(VoiceActions.countsSentence(plays: 1, skips: 0) == "You've played it once and never skipped it.")
        #expect(VoiceActions.countsSentence(plays: 0, skips: 2)
            == "You've skipped it twice and never played it through.")
        #expect(VoiceActions.countsSentence(plays: 2, skips: 5) == "You've played it twice and skipped it 5 times.")
    }

    // MARK: - Helpers

    @discardableResult
    private func albumCatalog(_ fixture: PlaybackFixture) throws -> FakePlaybackCatalog {
        let catalog = FakePlaybackCatalog()
        catalog.contents[.album] = try FakePlaybackCatalog.album()
        fixture.controller.playbackCatalog = catalog.catalog
        fixture.controller.collectionTrackCache = DevicePlaybackCache(directory: nil)
        return catalog
    }

    /// Song 0's album playing, moved on to a song Overplay does not track.
    private func playUntrackedAlbumSong(_ fixture: PlaybackFixture) async throws {
        try albumCatalog(fixture)
        await play(fixture, startingAt: 0)
        await fixture.controller.playCurrentCollection(.album, context: fixture.context)
        await fixture.player.externallyAdvance()
        #expect(fixture.controller.canAddCurrentToOverplay)
    }

    private func play(_ fixture: PlaybackFixture, startingAt index: Int) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[index],
                                              settings: fixture.settings, context: fixture.context)
    }

    /// Counts keep a retired song from the retention rule, so the test is
    /// about undo rather than deletion.
    private func keep(_ index: Int, in fixture: PlaybackFixture) throws {
        try fixture.item(index).skipCount = 2
        try fixture.context.save()
    }

    private func addOneTruePlaylist(to fixture: PlaybackFixture) throws -> PlaylistRecord {
        let otp = PlaylistRecord(musicPlaylistID: "playlist-otp", name: "One True", role: .oneTruePlaylist)
        fixture.context.insert(otp)
        try fixture.context.save()
        return otp
    }

    /// Apple Music adds succeed; iCloud's copy holds `cloudHolds`, and this
    /// device cannot edit playlists, so a removal waits as it would on a Mac.
    private func stubAppleMusic(_ fixture: PlaybackFixture, cloudHolds: [String] = []) {
        let entries = cloudHolds.map { AppleMusicLibraryPlaylistResources.Entry(id: $0, type: "library-songs") }
        var mutations = PlaylistMutationService(addRemotely: { _, _, _ in })
        mutations.remoteMembership.cloudEntries = { _ in [] }
        fixture.controller.playlistMutations = mutations
        fixture.controller.remoteMembership.cloudEntries = { _ in entries }
        fixture.controller.remoteMembership.canEditPlaylists = { false }
    }
}
