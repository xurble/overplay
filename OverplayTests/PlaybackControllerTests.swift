import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// Drives the controller only through its public actions and the player's own
/// behaviour, against a fake that re-issues IDs, crosses identifier domains,
/// hydrates late and fails (spec: Cross-Surface Playback Consistency).
@MainActor
@Suite("Playback controller", .serialized)
struct PlaybackControllerTests {
    // MARK: - Intent (`PLAY-010`)

    @Test func startingPlaybackPersistsTheIntentAndSubmitsOnce() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)

        let intent = try #require(fixture.intentStore.loadIntent())
        #expect(intent.members.map(\.title) == ["Song 0", "Song 1", "Song 2"])
        #expect(intent.startingLocalTrackID == fixture.tracks[1].id.uuidString)
        #expect(fixture.player.submitCount == 1)
        #expect(fixture.player.submittedStartIndices == [1])
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        #expect(fixture.controller.currentMember?.localTrackID == fixture.tracks[1].id.uuidString)
        #expect(fixture.controller.isPlaying)
    }

    @Test func intentSurvivesFailuresUnattributableEntriesAndSync() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        let intent = try #require(fixture.controller.intent)

        fixture.player.replaceCurrentItem(with: PlayerItemSnapshot(
            id: "foreign", identifiers: ["foreign"], title: "Someone Else", artistName: "Elsewhere",
            albumTitle: nil, artworkURLTemplate: nil, durationSeconds: 200))
        await fixture.player.externallyAdvance()
        fixture.player.reissueEntryIDs()
        await fixture.player.notify()
        fixture.player.nextFailuresRemaining = 1
        await fixture.controller.next(settings: fixture.settings, context: fixture.context)
        fixture.controller.reconcileStoredOrder(for: fixture.playlist, context: fixture.context)

        #expect(fixture.controller.intent == intent)
        #expect(fixture.intentStore.loadIntent() == intent)
        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        #expect(fixture.player.submitCount == 1)
    }

    // MARK: - Attribution (`PLAY-011`, `PLAY-012`)

    @Test func reissuedEntryIDsStillAttributeAndCount() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        fixture.player.reissueEntryIDs()
        await fixture.player.notify()

        #expect(fixture.controller.currentMember?.localTrackID == fixture.tracks[0].id.uuidString)
        await fixture.listen(to: 170)
        #expect(try fixture.item(0).playthroughCount == 1)
    }

    @Test func otherDomainItemIDsAttributeByMetadata() async throws {
        let player = FakePlaybackPlayer()
        player.reportedIDForSubmittedID = { _ in "1440887303" }
        let fixture = try PlaybackFixture(player: player)
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[2],
                                              settings: fixture.settings, context: fixture.context)

        #expect(fixture.controller.currentMember?.localTrackID == fixture.tracks[2].id.uuidString)
        #expect(fixture.controller.currentPlaylistRole(context: fixture.context) == .oneTruePlaylist)
    }

    @Test func unattributableEntryIsDisplayedNotCountedAndKeepsContext() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        fixture.player.replaceCurrentItem(with: PlayerItemSnapshot(
            id: "x", identifiers: ["x"], title: "Unknown Song", artistName: "Unknown",
            albumTitle: nil, artworkURLTemplate: nil, durationSeconds: 180))
        fixture.player.reissueEntryIDs()
        await fixture.player.notify()

        #expect(fixture.controller.currentTrack?.title == "Unknown Song")
        #expect(fixture.controller.currentMember == nil)
        #expect(fixture.controller.currentPlaylistRole(context: fixture.context) == nil)
        #expect(fixture.controller.currentPlaylistID == fixture.playlist.musicPlaylistID)
        await fixture.listen(to: 170)
        await fixture.player.externallyAdvance()
        #expect(try fixture.item(0).playthroughCount == 0)
        #expect(fixture.controller.currentMember?.localTrackID == fixture.tracks[1].id.uuidString)
    }

    @Test func lateHydrationAttributesAndStillCounts() async throws {
        let player = FakePlaybackPlayer()
        player.hydratesOnSubmit = false
        let fixture = try PlaybackFixture(player: player)
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        #expect(fixture.controller.currentTrack?.title == "Song 0")

        await fixture.listen(seconds: 3)
        fixture.player.hydrateAll()
        await fixture.player.notify()
        #expect(fixture.controller.currentMember?.localTrackID == fixture.tracks[0].id.uuidString)
        await fixture.listen(to: 170)
        #expect(try fixture.item(0).playthroughCount == 1)
    }

    // MARK: - Counting through observation (`COUNT-001`, `SURFACE-002`)

    @Test func externalSkipCountsTheOutgoingTrackOnce() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        await fixture.listen(seconds: 20)
        await fixture.player.externallyAdvance()
        await fixture.player.notify()

        #expect(try fixture.item(0).skipCount == 1)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        #expect(fixture.controller.currentMember?.localTrackID == fixture.tracks[1].id.uuidString)
    }

    @Test func previousFromAnySurfaceIsNotASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)
        await fixture.listen(seconds: 20)
        await fixture.player.externallySelect(index: 0)

        #expect(try fixture.item(1).skipCount == 0)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
    }

    @Test func playthroughCountsOnceAtTheThreshold() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        await fixture.listen(to: 165)
        await fixture.listen(seconds: 10)
        await fixture.player.externallyAdvance()

        #expect(try fixture.item(0).playthroughCount == 1)
        #expect(try fixture.item(0).skipCount == 0)
    }

    // MARK: - Transport and failure (`PLAY-013`, `PLAY-014`)

    @Test func transportActionsAreSingleCalls() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        let before = fixture.player.commands.count
        await fixture.controller.next(settings: fixture.settings, context: fixture.context)
        await fixture.controller.previous(context: fixture.context)
        await fixture.controller.toggleShuffle(context: fixture.context)
        fixture.controller.pause()

        #expect(Array(fixture.player.commands.dropFirst(before)) == ["next", "previous", "shuffle=songs", "pause"])
        #expect(fixture.controller.shuffleEnabled)
    }

    @Test func failedPlayIsSharedAndRecoveredOnlyByTheUserLadder() async throws {
        let player = FakePlaybackPlayer()
        player.playFailuresRemaining = 1
        let fixture = try PlaybackFixture(player: player)
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        #expect(fixture.controller.playbackFailure != nil)
        #expect(fixture.controller.intent != nil)
        #expect(fixture.player.submitCount == 1)

        // Nothing retries on its own.
        await fixture.player.notify()
        await fixture.controller.samplePlayback()
        #expect(fixture.player.playCount == 1)

        // Rung 1 fails, rung 2 (prepare, play) succeeds; no resubmission.
        fixture.player.playFailuresRemaining = 1
        await fixture.controller.play(context: fixture.context)
        #expect(Array(fixture.player.commands.suffix(3)) == ["play", "prepare", "play"])
        #expect(fixture.player.submitCount == 1)
        #expect(fixture.controller.playbackFailure == nil)
    }

    @Test func recoveryResubmitsTheIntentAsTheLastRung() async throws {
        let player = FakePlaybackPlayer()
        player.playFailuresRemaining = 1
        let fixture = try PlaybackFixture(player: player)
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[2],
                                              settings: fixture.settings, context: fixture.context)
        // Rung 1 (play) and rung 2 (prepare) fail; rung 3 resubmits and plays.
        fixture.player.playFailuresRemaining = 1
        fixture.player.prepareFailuresRemaining = 1
        await fixture.controller.play(context: fixture.context)

        #expect(fixture.player.submitCount == 2)
        #expect(fixture.player.submittedStartIndices.last == 2)
        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.controller.currentTrack?.title == "Song 2")
    }

    @Test func pauseIsNeverDisabledByAFailure() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
        #expect(fixture.controller.playbackFailure?.kind == .stalled)
        fixture.controller.pause()
        #expect(fixture.player.commands.last == "pause")
        #expect(fixture.player.playbackStatus == .paused)
    }

    @Test func stallClearsWhenProgressResumes() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
        #expect(fixture.controller.playbackFailure != nil)
        await fixture.listen(seconds: 2)
        #expect(fixture.controller.playbackFailure == nil)
    }

    // MARK: - Selection (`SURFACE-003`)

    @Test func selectingAnIntentMemberJumpsWithoutResubmitting() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        fixture.player.reissueEntryIDs()
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[2],
                                              settings: fixture.settings, context: fixture.context)

        #expect(fixture.player.submitCount == 1)
        #expect(fixture.player.commands.suffix(2) == ["select", "play"])
        #expect(fixture.controller.currentTrack?.title == "Song 2")
    }

    @Test func selectingTheCurrentTrackResumesWithoutRestarting() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)
        await fixture.listen(seconds: 30)
        fixture.controller.pause()
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)

        #expect(fixture.player.submitCount == 1)
        #expect(!fixture.player.commands.contains("select"))
        #expect(fixture.player.playbackTime == 30)
        #expect(fixture.player.playbackStatus == .playing)
    }

    @Test func shuffleAndPlayAppliesShuffleToTheLoadedQueue() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, settings: fixture.settings, context: fixture.context)
        #expect(Array(fixture.player.commands.suffix(2)) == ["shuffle=off", "shuffle=songs"])
        #expect(fixture.controller.shuffleEnabled)
    }

    @Test func oneUnpreparableTrackDoesNotPreventPlayback() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        DevicePlaybackCache.shared.set(nil, for: fixture.tracks[1].id)
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)

        #expect(fixture.player.submittedTitles.last == ["Song 0", "Song 2"])
        #expect(fixture.controller.isPlaying)
        #expect(fixture.controller.statusMessage?.contains("left out") == true)
    }

    // MARK: - Membership changes (`PLAY-015`)

    @Test func membershipChangesNeverTouchTheLiveQueue() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        let before = fixture.player.commands
        try fixture.controller.retireTrack(try fixture.item(2), playlist: fixture.playlist,
                                           message: "Retired", context: fixture.context)
        fixture.controller.reconcileStoredOrder(for: fixture.playlist, context: fixture.context)
        fixture.controller.reconcileTrackMembership(context: fixture.context)

        #expect(fixture.player.commands == before)
    }

    @Test func aMemberThatLeftTheScopeIsSkippedWhenReached() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        try fixture.controller.retireTrack(try fixture.item(1), playlist: fixture.playlist,
                                           message: "Retired", context: fixture.context)
        await fixture.player.externallyAdvance()

        #expect(fixture.player.commands.last == "next")
        #expect(fixture.controller.currentTrack?.title == "Song 2")
        #expect(try fixture.item(1).skipCount == 0)
    }

    @Test func retiringTheCurrentTrackAdvancesWithoutASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        await fixture.listen(seconds: 20)
        await fixture.controller.evictCurrent(settings: fixture.settings, context: fixture.context)

        #expect(try fixture.item(0).evictedAt != nil)
        #expect(try fixture.item(0).skipCount == 0)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
    }

    @Test func identityMergeRekeysTheIntentAndFollowsTheKeeper() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)
        let keeper = fixture.tracks[0], donor = fixture.tracks[1]
        let keeperItem = try fixture.item(0), donorItem = try fixture.item(1)
        TrackIdentityMergeService.absorb(donor, into: keeper, confirmed: true)
        fixture.context.delete(donorItem)
        fixture.context.delete(donor)
        try fixture.context.save()
        let commandsBefore = fixture.player.commands

        fixture.controller.applyDuplicateMerge(DuplicateTrackService.Result(
            trackID: keeper.id, itemID: keeperItem.id, mapping: [donor.id.uuidString: keeper.id.uuidString],
            remoteRemovalIDs: [], previousOTP: nil
        ), context: fixture.context)

        #expect(fixture.controller.currentMember?.localTrackID == keeper.id.uuidString)
        #expect(fixture.controller.currentPlaylistItem?.id == keeperItem.id)
        #expect(fixture.controller.intent?.members.count == 2)
        #expect(fixture.intentStore.loadIntent()?.members.contains { $0.localTrackID == donor.id.uuidString } == false)
        #expect(fixture.player.commands == commandsBefore)
    }

    // MARK: - Launch and restore

    @Test func relaunchWhileThePlayerIsStillPlayingReattaches() async throws {
        let first = try PlaybackFixture()
        defer { first.cleanUp() }
        await first.controller.playPlaylist(first.playlist, startingAt: first.tracks[1],
                                            settings: first.settings, context: first.context)
        first.controller.stopMonitoring()

        let relaunched = PlaybackController(player: first.player, intentStore: first.intentStore,
                                            preparePlaybackTracks: { _ in }, refreshUnknownApplePlayCount: { _, _ in 0 },
                                            sleep: PlaybackFixture.manualSampling)
        relaunched.restoreLocalPlaybackDisplay(context: first.context)
        await relaunched.reconcilePlayerState(context: first.context)

        #expect(relaunched.currentMember?.localTrackID == first.tracks[1].id.uuidString)
        #expect(relaunched.isPlaying)
        #expect(first.player.submitCount == 1)
        relaunched.stopMonitoring()
    }

    @Test func restoredIntentResumesAtItsMemberAndPosition() async throws {
        let first = try PlaybackFixture()
        defer { first.cleanUp() }
        await first.controller.playPlaylist(first.playlist, startingAt: first.tracks[2],
                                            settings: first.settings, context: first.context)
        await first.listen(seconds: 40)
        first.controller.pause()
        first.controller.stopMonitoring()

        let player = FakePlaybackPlayer()
        let relaunched = PlaybackController(player: player, intentStore: first.intentStore,
                                            preparePlaybackTracks: { _ in }, refreshUnknownApplePlayCount: { _, _ in 0 },
                                            sleep: PlaybackFixture.manualSampling)
        relaunched.restoreIntent()
        #expect(relaunched.currentTrack?.title == "Song 2")
        #expect(relaunched.elapsedSeconds == 40)
        #expect(!relaunched.isPlaying)

        await relaunched.play(context: first.context)
        #expect(player.submittedStartIndices == [2])
        #expect(player.playbackTime == 40)
        #expect(relaunched.isPlaying)
        relaunched.stopMonitoring()
    }

    @Test func playbackWorksBeforeTheLibraryIsRestoredButDoesNotCount() async throws {
        let first = try PlaybackFixture()
        defer { first.cleanUp() }
        await first.controller.playPlaylist(first.playlist, startingAt: first.tracks[0],
                                            settings: first.settings, context: first.context)
        first.controller.stopMonitoring()

        let player = FakePlaybackPlayer()
        let relaunched = PlaybackController(player: player, intentStore: first.intentStore,
                                            preparePlaybackTracks: { _ in }, refreshUnknownApplePlayCount: { _, _ in 0 },
                                            sleep: PlaybackFixture.manualSampling)
        relaunched.isLibraryReady = { false }
        relaunched.restoreIntent()
        relaunched.startMonitoring()
        await relaunched.play(context: first.context)
        #expect(player.submitCount == 1)
        #expect(relaunched.isPlaying)

        player.playbackTime = 170
        await relaunched.samplePlayback()
        await player.externallyAdvance()
        #expect(try first.item(0).playthroughCount == 0)
        relaunched.stopMonitoring()
    }

    @Test func queueEndKeepsTheIntentAndPlayStartsFromTheBeginning() async throws {
        let fixture = try PlaybackFixture(trackCount: 2)
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)
        await fixture.listen(to: 179)
        await fixture.player.externallyAdvance()

        #expect(fixture.controller.intent != nil)
        #expect(!fixture.controller.hasLiveQueue)
        #expect(try fixture.item(1).playthroughCount == 1)
        await fixture.controller.play(context: fixture.context)
        #expect(fixture.player.submittedStartIndices.last == 0)
    }
}
