import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// Player commands that fail or do not take, through the controller's shared
/// entry points (TST-4). Each test pins what the controller does today.
@MainActor
@Suite("Player commands that fail or do not take", .serialized)
struct PlayerCommandFailureTests {
    private func fixture() throws -> PlaybackFixture {
        let fixture = try PlaybackFixture()
        fixture.controller.activityLog = MusicKitActivityLog(fileURL: nil)
        return fixture
    }

    private func select(_ fixture: PlaybackFixture, _ index: Int) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[index],
                                              settings: fixture.settings, context: fixture.context)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    // MARK: - Select

    @Test func aSelectThatFailsShowsTheFailureAndKeepsTheQueue() async throws {
        // Only a missing entry falls back to a fresh queue; any other error
        // is the player's to report. Today the wrapper throws nothing else.
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 0)
        fixture.player.selectFailure = FakePlaybackPlayer.Failure.commandFailed
        let commandsBefore = fixture.player.commands.count

        await select(fixture, 2)

        #expect(Array(fixture.player.commands[commandsBefore...]) == ["select"])
        #expect(fixture.player.submitCount == 1)
        #expect(fixture.controller.playbackFailure?.kind == .command)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        #expect(fixture.player.currentEntry?.item?.title == "Song 0")
    }

    // MARK: - Previous

    @Test func aPreviousThatFailsLeavesThePlayerWhereItWas() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 1)
        await fixture.listen(seconds: 10)
        fixture.player.previousFailuresRemaining = 1

        await fixture.controller.previous(context: fixture.context)

        #expect(fixture.player.commands.last == "previous")
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        #expect(fixture.controller.elapsedSeconds == 10)
        #expect(fixture.controller.isPlaying)
        // Logged only; nothing is shown, as for a failed Next.
        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.controller.statusMessage == nil)

        // The next press is sent as usual.
        await fixture.controller.previous(context: fixture.context)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
    }

    // MARK: - Pause

    @Test func aPauseThePlayerIgnoresIsShownUntilTheNextSample() async throws {
        // 2026-10-19: an in-app Pause was ignored. Today Overplay shows paused
        // at once, before the player has said so, which the observe-only rule
        // (AGENTS.md) does not allow; the next sample shows it playing again.
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 0)
        await fixture.listen(seconds: 10)
        fixture.player.ignoresPause = true

        fixture.controller.pause()

        #expect(fixture.player.commands.last == "pause")
        #expect(fixture.player.playbackStatus == .playing)
        #expect(!fixture.controller.isPlaying)

        await fixture.listen(seconds: 1)
        #expect(fixture.controller.isPlaying)
        #expect(fixture.controller.elapsedSeconds == 11)
        #expect(fixture.controller.playbackFailure == nil)

        // Pause again is sent again: no command is refused.
        let pausesBefore = fixture.player.commands.filter { $0 == "pause" }.count
        fixture.controller.pause()
        #expect(fixture.player.commands.filter { $0 == "pause" }.count == pausesBefore + 1)
    }

    // MARK: - Shuffle and repeat

    @Test func modeWritesThatDoNotTakeAreNotShown() async throws {
        // MusicKit owns the modes (`PLAY-004`): the controller reads them back.
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 0)
        #expect(!fixture.controller.shuffleEnabled)
        #expect(!fixture.controller.repeatAllEnabled)
        fixture.player.ignoresModeWrites = true

        await fixture.controller.setShuffleEnabled(true, context: fixture.context)
        await fixture.controller.setRepeatMode(.all, context: fixture.context)

        #expect(Array(fixture.player.commands.suffix(2)) == ["shuffle=songs", "repeat=all"])
        #expect(!fixture.controller.shuffleEnabled)
        #expect(!fixture.controller.repeatAllEnabled)
    }

    // MARK: - Observation

    @Test func aStateOnlyChangeIsObserved() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 0)
        #expect(fixture.controller.isPlaying)

        fixture.player.playbackStatus = .paused
        await fixture.player.notify([.state])

        #expect(!fixture.controller.isPlaying)
    }

    @Test func aQueueOnlyChangeIsObserved() async throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 0)

        fixture.player.silentlyAdvance(to: 0)
        await fixture.player.notify([.queue])

        #expect(fixture.controller.currentTrack?.title == "Song 1")
        #expect(fixture.controller.isPlaying)
    }

    // MARK: - Submit

    @Test func aStartWhoseQueueDoesNotTakeIsNotReportedAsAFailure() async throws {
        // The empty queue never loads, so the start waits out the load limit
        // on the manual clock, then plays nothing. Today that start counts as
        // played: it clears any failure and shows the song stopped, with no
        // message. Only a Play press would find there is no queue.
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        let clock = ManualPlaybackClock()
        fixture.controller.clock = clock.clock
        fixture.player.submitFailuresRemaining = 1

        let starting = Task { await select(fixture, 0) }
        try await waitUntil { clock.pending(.milliseconds(50)) == 1 }
        await clock.advance(by: fixture.controller.queueLoadLimit)
        await starting.value

        #expect(fixture.player.submitCount == 1)
        #expect(fixture.player.commands.contains("play"))
        #expect(fixture.player.currentEntryID == nil)
        #expect(fixture.player.playbackStatus == .stopped)
        #expect(!fixture.controller.isPlaying)
        #expect(!fixture.controller.hasLiveQueue)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.controller.statusMessage == nil)
    }
}
