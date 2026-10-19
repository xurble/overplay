import Foundation
import SwiftData
import Testing
@testable import Overplay

/// Siri's actions (`SIRI-001`) through the shared entry points the app and
/// CarPlay use, Shuffle and Play resuming the current playlist (`PLAY-020`),
/// and undoing the last promote or retire (`MUT-003`).
@MainActor
@Suite("Voice actions and undo", .serialized)
struct VoiceActionTests {
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

    // MARK: - Helpers

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
