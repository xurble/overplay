import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// Regressions for the 2026-10-05 fresh-context review of the playback rewrite.
@MainActor
@Suite("Playback controller review fixes", .serialized)
struct PlaybackControllerReviewFixTests {
    private func start(_ fixture: PlaybackFixture, at index: Int) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[index],
                                              settings: fixture.settings, context: fixture.context)
    }

    // Finding 2
    @Test func reissuedEntryIDsMidTrackAreTheSameSessionNotASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        fixture.player.reissueEntryIDs()
        await fixture.player.notify()

        #expect(try fixture.item(0).skipCount == 0)
        #expect(fixture.controller.currentMember?.localTrackID == fixture.tracks[0].id.uuidString)
        await fixture.listen(to: 170)
        #expect(try fixture.item(0).playthroughCount == 1)
        #expect(try fixture.item(0).skipCount == 0)
    }

    @Test func unhydratedReissueIsHeldUntilTheItemConfirmsIt() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        fixture.player.reissueEntryIDs(droppingItems: true)
        await fixture.player.notify()
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        fixture.player.hydrateAll()
        await fixture.player.notify()
        await fixture.player.externallyAdvance()

        #expect(try fixture.item(0).skipCount == 1)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
    }

    // Finding 3
    @Test func primaryActionDuringAStallRetriesInsteadOfPausing() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
        #expect(fixture.controller.playbackFailure?.kind == .stalled)
        let presentation = NowPlayingPresentationFactory.playbackControlsPresentation(playbackController: fixture.controller)
        #expect(!presentation.isPlaying)

        let before = fixture.player.commands.count
        await fixture.controller.performPrimaryPlaybackAction(settings: fixture.settings, context: fixture.context)
        let issued = Array(fixture.player.commands.dropFirst(before))
        #expect(!issued.contains("pause"))
        #expect(issued.prefix(2) == ["prepare", "play"])
    }

    @Test func repeatedStallRecoveryEscalatesToResubmission() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 1)
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
        await fixture.controller.play(context: fixture.context)
        #expect(fixture.player.submitCount == 1)
        // Still frozen: the stall comes back, and the next press goes further.
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
        #expect(fixture.controller.playbackFailure?.kind == .stalled)
        await fixture.controller.play(context: fixture.context)
        #expect(fixture.player.submitCount == 2)
        #expect(fixture.player.submittedStartIndices.last == 1)
    }

    // Finding 4
    @Test func witnessedProgressClearsACommandFailure() async throws {
        let player = FakePlaybackPlayer()
        player.playFailuresRemaining = 1
        let fixture = try PlaybackFixture(player: player)
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        #expect(fixture.controller.playbackFailure?.kind == .command)
        // MusicKit started playing anyway.
        player.playbackStatus = .playing
        await fixture.player.notify()
        await fixture.listen(seconds: 2)
        #expect(fixture.controller.playbackFailure == nil)
    }

    // Finding 5
    @Test func recoveryResubmissionContinuesTheSessionWithoutASkip() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
        fixture.player.prepareFailuresRemaining = 1
        await fixture.controller.play(context: fixture.context)

        #expect(fixture.player.submitCount == 2)
        #expect(try fixture.item(0).skipCount == 0)
        await fixture.listen(to: 170)
        #expect(try fixture.item(0).playthroughCount == 1)
    }

    // Finding 6
    @Test func queueEndWhileSuspendedIsNotAFailure() async throws {
        let fixture = try PlaybackFixture(trackCount: 2)
        defer { fixture.cleanUp() }
        await start(fixture, at: 1)
        fixture.player.playbackTime = 30
        await fixture.controller.samplePlayback(now: Date.now.addingTimeInterval(-600))
        await fixture.player.externallyAdvance()

        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
    }

    @Test func aFreshMidTrackStopKeepsTheTrackAndPositionForResume() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 1)
        await fixture.listen(seconds: 40)
        await fixture.player.abandonQueue()

        #expect(fixture.controller.playbackFailure?.kind == .command)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        await fixture.controller.play(context: fixture.context)
        #expect(fixture.player.submittedStartIndices.last == 1)
        #expect(fixture.player.playbackTime == 40)
    }

    // Finding 9
    @Test func aSlowerOlderStartCannotOverrideANewerSelection() async throws {
        let gate = PreparationGate()
        let fixture = try PlaybackFixture(preparePlaybackTracks: { _, _ in await gate.waitOnFirstCall() })
        defer { fixture.cleanUp() }
        let slow = Task { await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                                                settings: fixture.settings, context: fixture.context) }
        await gate.untilFirstCallIsWaiting()
        await start(fixture, at: 2)
        gate.release()
        await slow.value

        #expect(fixture.player.submitCount == 1)
        #expect(fixture.player.submittedStartIndices == [2])
        #expect(fixture.controller.currentTrack?.title == "Song 2")
    }

    // Finding 11
    @Test func skipOnReachNeverLoopsWhenEverythingLeftTheScope() async throws {
        let fixture = try PlaybackFixture(trackCount: 2)
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.controller.setRepeatMode(.all, context: fixture.context)
        for index in 0..<2 {
            try fixture.controller.retireTrack(try fixture.item(index), playlist: fixture.playlist,
                                               message: "Retired", context: fixture.context)
        }
        await fixture.player.externallyAdvance()

        #expect(fixture.player.commands.filter { $0 == "next" }.count <= 2)
    }

    // Finding 12
    @Test func relaunchWithAnUnhydratedEntryDoesNotGuessTheOldStartTrack() async throws {
        let first = try PlaybackFixture()
        defer { first.cleanUp() }
        await start(first, at: 0)
        await first.player.externallyAdvance()
        first.controller.stopMonitoring()
        first.player.dehydrateCurrent()

        let relaunched = PlaybackController(player: first.player, intentStore: first.intentStore,
                                            preparePlaybackTracks: { _, _ in }, refreshUnknownApplePlayCount: { _, _ in 0 },
                                            sleep: PlaybackFixture.manualSampling)
        relaunched.restoreLocalPlaybackDisplay(context: first.context)
        await relaunched.reconcilePlayerState(context: first.context)
        #expect(relaunched.currentMember?.localTrackID != first.tracks[0].id.uuidString)
        first.player.hydrateAll()
        await first.player.notify()
        #expect(relaunched.currentMember?.localTrackID == first.tracks[1].id.uuidString)
        relaunched.stopMonitoring()
    }

    // Finding 13
    @Test func monitoringReadsAnAlreadyLoadedQueueAtLaunch() async throws {
        let first = try PlaybackFixture()
        defer { first.cleanUp() }
        await start(first, at: 1)
        first.controller.pause()
        first.controller.stopMonitoring()

        let relaunched = PlaybackController(player: first.player, intentStore: first.intentStore,
                                            preparePlaybackTracks: { _, _ in }, refreshUnknownApplePlayCount: { _, _ in 0 },
                                            sleep: PlaybackFixture.manualSampling)
        relaunched.restoreIntent()
        relaunched.startMonitoring()
        for _ in 0..<20 where !relaunched.hasLiveQueue { await Task.yield() }
        #expect(relaunched.hasLiveQueue)
        relaunched.stopMonitoring()
    }

    // Finding 16
    @Test func aRepeatAllWrapIsForwardSoASkipStillCounts() async throws {
        let fixture = try PlaybackFixture(trackCount: 2)
        defer { fixture.cleanUp() }
        await start(fixture, at: 1)
        await fixture.controller.setRepeatMode(.all, context: fixture.context)
        await fixture.listen(seconds: 20)
        await fixture.player.externallyAdvance()

        #expect(fixture.controller.currentTrack?.title == "Song 0")
        #expect(try fixture.item(1).skipCount == 1)
    }

    // Finding 8
    @Test func carPlayShowsNowPlayingWhenATrackWasLeftOut() {
        let requested = PlaylistPlaybackContext(musicPlaylistID: "p", scope: .active)
        #expect(CarPlayPlaybackOutcome.decide(hasPlaybackFailure: false, current: requested, requested: requested) == .nowPlaying)
        #expect(CarPlayPlaybackOutcome.decide(hasPlaybackFailure: true, current: requested, requested: requested) == .sharedFailure)
        #expect(CarPlayPlaybackOutcome.decide(hasPlaybackFailure: false, current: nil, requested: requested) == .notStarted)
        let otherScope = PlaylistPlaybackContext(musicPlaylistID: "p", scope: .retired)
        #expect(CarPlayPlaybackOutcome.decide(hasPlaybackFailure: false, current: otherScope, requested: requested) == .notStarted)
    }
}

/// Holds the first preparation until released, to order concurrent starts.
@MainActor
final class PreparationGate {
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitOnFirstCall() async {
        calls += 1
        guard calls == 1 else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func untilFirstCallIsWaiting() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
