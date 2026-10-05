import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// Regressions for the third fresh-context review of PR #62.
@MainActor
@Suite("Playback controller review round 3", .serialized)
struct PlaybackControllerReviewRound3Tests {
    private func start(_ fixture: PlaybackFixture, at index: Int) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[index],
                                              settings: fixture.settings, context: fixture.context)
    }

    private func stall(_ fixture: PlaybackFixture) async {
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
    }

    // F1
    @Test func aTrackRetiredAfterItPlayedIsSkippedOnTheNextLap() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await fixture.controller.setRepeatMode(.all, context: fixture.context)
        await fixture.player.externallyAdvance()
        await fixture.player.externallyAdvance()
        await fixture.player.externallyAdvance()
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        try fixture.controller.retireTrack(try fixture.item(1), playlist: fixture.playlist,
                                           message: "Retired", context: fixture.context)
        await fixture.player.externallyAdvance()

        #expect(fixture.player.commands.last == "next")
        #expect(fixture.controller.currentTrack?.title == "Song 2")
    }

    // F3
    @Test func aMergeKeepsTheResumePointOnTheSameSong() async throws {
        let first = try PlaybackFixture()
        defer { first.cleanUp() }
        await start(first, at: 1)
        await first.listen(seconds: 40)
        first.controller.pause()
        let keeper = first.tracks[2], donor = first.tracks[1]
        TrackIdentityMergeService.absorb(donor, into: keeper, confirmed: true)
        first.controller.applyDuplicateMerge(DuplicateTrackService.Result(
            trackID: keeper.id, itemID: try first.item(2).id, mapping: [donor.id.uuidString: keeper.id.uuidString],
            remoteRemovalIDs: [], previousOTP: nil
        ), context: first.context)
        first.controller.stopMonitoring()

        let relaunched = PlaybackController(player: FakePlaybackPlayer(), intentStore: first.intentStore,
                                            preparePlaybackTracks: { _ in }, sleep: PlaybackFixture.manualSampling)
        relaunched.restoreIntent()
        #expect(relaunched.currentMember?.localTrackID == keeper.id.uuidString)
        #expect(relaunched.elapsedSeconds == 40)
    }

    @Test func aResumePointForAMissingTrackStartsAtZero() async throws {
        let first = try PlaybackFixture()
        defer { first.cleanUp() }
        await start(first, at: 1)
        let intent = try #require(first.controller.intent)
        first.controller.stopMonitoring()
        first.intentStore.save(PlaybackResumePoint(intentID: intent.id, localTrackID: UUID().uuidString,
                                                   positionSeconds: 95, wasPlaying: false, updatedAt: .now))

        let relaunched = PlaybackController(player: FakePlaybackPlayer(), intentStore: first.intentStore,
                                            preparePlaybackTracks: { _ in }, sleep: PlaybackFixture.manualSampling)
        relaunched.restoreIntent()
        #expect(relaunched.elapsedSeconds == 0)
    }

    // F4
    @Test func aSecondPressDuringRungThreeSupersedesItWithoutRungTwo() async throws {
        let gate = NthCallGate(call: 2)
        let fixture = try PlaybackFixture(preparePlaybackTracks: { _ in await gate.arrive() })
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await stall(fixture)
        fixture.player.prepareFailuresRemaining = 1
        let firstPress = Task { await fixture.controller.play(context: fixture.context) }
        await gate.untilHeld()
        await fixture.controller.play(context: fixture.context)
        gate.release()
        await firstPress.value

        #expect(fixture.player.commands.filter { $0 == "prepare" }.count == 1)
        #expect(fixture.player.submitCount == 2)
        #expect(fixture.controller.playbackFailure == nil)
    }

    // F5
    private func carryPastTheLimitThenHydrateAs400sSong2(_ fixture: PlaybackFixture) async {
        await start(fixture, at: 0)
        await fixture.listen(seconds: 20)
        fixture.player.reissueEntryIDs(droppingItems: true)
        await fixture.player.notify()
        fixture.player.playbackTime += 1
        await fixture.controller.samplePlayback(now: .now.addingTimeInterval(PlaybackController.unconfirmedCarryOverLimit + 1))
        // The entry turns out to be a different, longer song.
        fixture.player.replaceCurrentItem(with: PlayerItemSnapshot(
            id: "i.lib-2", identifiers: ["i.lib-2"], title: "Song 2", artistName: "Artist 2",
            albumTitle: nil, artworkURLTemplate: nil, durationSeconds: 400))
        await fixture.player.notify()
    }

    @Test func lateHydrationAfterTheLimitStillSplitsTheSession() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await carryPastTheLimitThenHydrateAs400sSong2(fixture)
        #expect(fixture.controller.currentMember?.localTrackID == fixture.tracks[2].id.uuidString)
        // Song 2's own session has barely been listened to, so leaving it
        // now is not a skip; the carried listening did not join it.
        await fixture.player.externallyAdvance()
        #expect(try fixture.item(2).skipCount == 0)
        #expect(try fixture.item(0).skipCount == 0)
    }

    @Test func lateHydrationAfterTheLimitUsesTheNewSongsDuration() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await carryPastTheLimitThenHydrateAs400sSong2(fixture)
        await fixture.listen(to: 170)
        #expect(try fixture.item(2).playthroughCount == 0)
    }

    // F6
    @Test func aMergeWhoseLineageHasNotArrivedIsNotSkipped() async throws {
        let fixture = try PlaybackFixture()
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        // The donor's item and track were deleted by a merge on another
        // device; the lineage event has not arrived yet.
        fixture.context.delete(try fixture.item(1))
        fixture.context.delete(fixture.tracks[1])
        try fixture.context.save()
        let commandsBefore = fixture.player.commands.count

        await fixture.player.externallyAdvance()
        #expect(!fixture.player.commands.dropFirst(commandsBefore).contains("next"))
        #expect(fixture.controller.currentTrack?.title == "Song 1")
    }
}

/// Holds the Nth call until released.
@MainActor
final class NthCallGate {
    private let call: Int
    private var calls = 0
    private var held: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(call: Int) { self.call = call }

    func arrive() async {
        calls += 1
        guard calls == call else { return }
        await withCheckedContinuation { continuation in
            held = continuation
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func untilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
