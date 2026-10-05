import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// Regressions for the second fresh-context review of PR #62.
@MainActor
@Suite("Playback controller review round 2", .serialized)
struct PlaybackControllerReviewRound2Tests {
    private func start(_ fixture: PlaybackFixture, at index: Int) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[index],
                                              settings: fixture.settings, context: fixture.context)
    }

    private func stall(_ fixture: PlaybackFixture) async {
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
    }

    // M1
    @Test func aPlayCreditedByReconciliationIsNotCountedAgainLive() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 5)
        // Suspended: the next track reaches 95% unheard, and the wake's point
        // proof credits it before the controller observes it.
        fixture.player.silentlyAdvance(to: 171)
        let item = try fixture.item(1)
        let session = TrackPlaySession(trackID: "i.lib-1", localTrackID: fixture.tracks[1].id.uuidString,
                                       sessionStartDate: .now, lastObservedPlaybackTime: 171, durationSeconds: 180,
                                       hasEvaluated: true)
        EvictionEngine.countPlaythrough(item, playlist: fixture.playlist, session: session, settings: fixture.settings,
                                        source: .reconciled, reconciliationMechanism: .pointObservation, context: fixture.context)
        #expect(item.playthroughCount == 1)

        await fixture.controller.reconcilePlayerState(context: fixture.context)
        await fixture.listen(seconds: 2)
        #expect(try fixture.item(1).playthroughCount == 1)
    }

    // M2
    @Test func aMergeOnAnotherDeviceFollowsTheKeeperInsteadOfSkipping() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        // Another device merged track 1 into track 0; CloudKit delivered it.
        let keeper = fixture.tracks[0], donor = fixture.tracks[1]
        TrackIdentityMergeService.absorb(donor, into: keeper, confirmed: true)
        fixture.context.delete(try fixture.item(1))
        fixture.context.delete(donor)
        try fixture.context.save()
        let commandsBefore = fixture.player.commands.count

        await fixture.player.externallyAdvance()

        #expect(!fixture.player.commands.dropFirst(commandsBefore).contains("next"))
        #expect(fixture.controller.currentMember?.localTrackID == keeper.id.uuidString)
        #expect(fixture.intentStore.loadIntent()?.members.contains { $0.localTrackID == donor.id.uuidString } == false)
    }

    // M3
    @Test func aRungTwoRecoveryGetsAFreshStallWindow() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await stall(fixture)
        await fixture.controller.play(context: fixture.context)
        #expect(fixture.controller.playbackFailure == nil)
        await fixture.controller.samplePlayback()
        await fixture.controller.samplePlayback()
        #expect(fixture.controller.playbackFailure == nil)
    }

    // L1
    @Test func selectingTheRestoredCurrentTrackResumesAtItsPosition() async throws {
        let first = try PlaybackFixture()
        defer { first.cleanUp() }
        await start(first, at: 2)
        await first.listen(seconds: 40)
        first.controller.pause()
        first.controller.stopMonitoring()

        let player = FakePlaybackPlayer()
        let relaunched = PlaybackController(player: player, intentStore: first.intentStore, preparePlaybackTracks: { _, _ in },
                                            refreshUnknownApplePlayCount: { _, _ in 0 }, sleep: PlaybackFixture.manualSampling)
        relaunched.restoreLocalPlaybackDisplay(context: first.context)
        await relaunched.playPlaylist(first.playlist, startingAt: first.tracks[2], settings: first.settings, context: first.context)
        #expect(player.playbackTime == 40)
        relaunched.stopMonitoring()
    }

    // L2
    @Test func previousInATwoTrackQueueIsNotASkip() async throws {
        let fixture = try PlaybackFixture(trackCount: 2)
        defer { fixture.cleanUp() }
        await start(fixture, at: 1)
        await fixture.listen(seconds: 20)
        await fixture.player.externallySelect(index: 0)
        #expect(try fixture.item(1).skipCount == 0)
    }

    @Test func previousFromTheFirstTrackUnderRepeatAllIsNotASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.controller.setRepeatMode(.all, context: fixture.context)
        await fixture.listen(seconds: 20)
        await fixture.player.externallySelect(index: 2)
        #expect(try fixture.item(0).skipCount == 0)
    }

    // L3
    @Test func anUnconfirmedCarryOverStopsCountingAfterItsLimit() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        fixture.player.reissueEntryIDs(droppingItems: true)
        await fixture.player.notify()
        fixture.player.playbackTime += 1
        await fixture.controller.samplePlayback(now: .now.addingTimeInterval(PlaybackController.unconfirmedCarryOverLimit + 1))
        await fixture.player.externallyAdvance()
        #expect(try fixture.item(0).skipCount == 0)
    }

    // L4
    @Test func aRecoveryThatStartsSomewhereUnexpectedDropsTheCarriedListen() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        await stall(fixture)
        fixture.player.prepareFailuresRemaining = 1
        fixture.player.nextSubmissionStartItem = PlayerItemSnapshot(
            id: "foreign", identifiers: ["foreign"], title: "Not Ours", artistName: "Elsewhere",
            albumTitle: nil, artworkURLTemplate: nil, durationSeconds: 200)
        await fixture.controller.play(context: fixture.context)
        #expect(fixture.player.submitCount == 2)
        #expect(try fixture.item(0).skipCount == 0)
    }

    // L5
    @Test func theFailureStaysWhileARungThreeResubmissionPrepares() async throws {
        var calls = 0
        var failureDuringPreparation: PlaybackFailure?
        var controller: PlaybackController?
        let fixture = try PlaybackFixture(preparePlaybackTracks: { _, _ in
            calls += 1
            if calls == 2 { failureDuringPreparation = controller?.playbackFailure }
        })
        defer { fixture.cleanUp() }
        controller = fixture.controller
        await start(fixture, at: 0)
        await stall(fixture)
        fixture.player.prepareFailuresRemaining = 1
        await fixture.controller.play(context: fixture.context)
        #expect(failureDuringPreparation != nil)
        #expect(fixture.controller.playbackFailure == nil)
    }

    // L7
    @Test func selectionIgnoresAStaleCachedAttribution() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.player.externallyAdvance()
        await fixture.player.externallyAdvance()
        // Entry 1 was attributed to track 1, but now carries another song.
        fixture.player.replaceItem(at: 1, with: PlayerItemSnapshot(
            id: "foreign", identifiers: ["foreign"], title: "Not Ours", artistName: "Elsewhere",
            albumTitle: nil, artworkURLTemplate: nil, durationSeconds: 200))
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)
        #expect(!fixture.player.commands.contains("select"))
        #expect(fixture.player.submitCount == 2)
    }

    @Test func aRetiredCurrentTrackIsNotSkippedWhenItsEntryIsReissued() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        try fixture.controller.retireTrack(try fixture.item(0), playlist: fixture.playlist,
                                           message: "Retired", context: fixture.context)
        let commandsBefore = fixture.player.commands.count
        fixture.player.reissueEntryIDs()
        await fixture.player.notify()
        #expect(!fixture.player.commands.dropFirst(commandsBefore).contains("next"))
    }
}
