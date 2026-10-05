import Foundation
import SwiftData
import Testing
@testable import Overplay

/// Regressions for the fourth fresh-context review of PR #62.
@MainActor
@Suite("Playback controller review round 4", .serialized)
struct PlaybackControllerReviewRound4Tests {
    private func start(_ fixture: PlaybackFixture, at index: Int) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[index],
                                              settings: fixture.settings, context: fixture.context)
    }

    private func stall(_ fixture: PlaybackFixture) async {
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
    }

    // R4-2
    @Test func rungThreeLooksUpTheStartTrackAgain() async throws {
        var refreshes: [Set<UUID>] = []
        let fixture = try PlaybackFixture(preparePlaybackTracks: { _, refreshing in refreshes.append(refreshing) })
        defer { fixture.cleanUp() }
        await start(fixture, at: 1)
        await stall(fixture)
        fixture.player.prepareFailuresRemaining = 1
        await fixture.controller.play(context: fixture.context)

        #expect(fixture.player.submitCount == 2)
        #expect(refreshes == [[], [fixture.tracks[1].id]])
    }

    @Test func resumingAfterRelaunchDoesNotLookUpCachedTracksAgain() async throws {
        let first = try PlaybackFixture()
        defer { first.cleanUp() }
        await start(first, at: 1)
        first.controller.stopMonitoring()

        var refreshes: [Set<UUID>] = []
        let player = FakePlaybackPlayer()
        let relaunched = PlaybackController(player: player, intentStore: first.intentStore,
                                            preparePlaybackTracks: { _, refreshing in refreshes.append(refreshing) },
                                            refreshUnknownApplePlayCount: { _, _ in 0 }, sleep: PlaybackFixture.manualSampling)
        relaunched.restoreIntent()
        await relaunched.play(context: first.context)
        defer { relaunched.stopMonitoring() }

        #expect(player.submitCount == 1)
        #expect(refreshes == [[]])
    }

    // R4-6
    @Test func noApplePlayCountLookupStartsDuringAFailure() async throws {
        var lookups: [UUID] = []
        let fixture = try PlaybackFixture(refreshUnknownApplePlayCount: { trackID, _ in
            lookups.append(trackID)
            return 0
        })
        defer { fixture.cleanUp() }
        await start(fixture, at: 0)
        await Task.yield()
        #expect(lookups == [fixture.tracks[0].id])

        await stall(fixture)
        #expect(fixture.controller.playbackFailure != nil)
        await fixture.player.externallyAdvance()
        for _ in 0..<5 { await Task.yield() }
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        #expect(lookups == [fixture.tracks[0].id])
    }
}
