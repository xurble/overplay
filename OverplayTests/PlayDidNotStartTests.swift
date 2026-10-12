import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// 2026-10-11, CarPlay on a slow connection with storage nearly full: Play
/// returned at once, the player reported `playing` with no audio, then fell
/// back to paused a few seconds later without announcing it. Every Play
/// press repeated that until Overplay was force-quit (`PLAY-014`).
@MainActor
@Suite("Play that did not start", .serialized)
struct PlayDidNotStartTests {
    private func fixture(freeStorage: Int64? = 50_000_000_000) async throws -> (PlaybackFixture, MusicKitActivityLog) {
        let fixture = try PlaybackFixture()
        let log = MusicKitActivityLog(fileURL: nil)
        fixture.controller.activityLog = log
        fixture.controller.freeStorageBytes = { freeStorage }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[1],
                                              settings: fixture.settings, context: fixture.context)
        return (fixture, log)
    }

    private func events(_ log: MusicKitActivityLog, _ operation: MusicKitActivityOperation) -> [String] {
        log.snapshot().events.filter { $0.operation == operation }.compactMap(\.detail)
    }

    /// The player reports `playing` without moving, then reports paused
    /// unannounced; only the one-second sample sees it.
    private func flicker(_ fixture: PlaybackFixture, after seconds: TimeInterval = 3) async {
        await fixture.controller.samplePlayback(now: .now + 1)
        fixture.player.playbackStatus = .paused
        await fixture.controller.samplePlayback(now: .now + seconds)
    }

    @Test func playingWithoutProgressThenPausedIsAFailure() async throws {
        let (fixture, log) = try await fixture()
        defer { fixture.cleanUp() }
        await flicker(fixture)

        let failure = try #require(fixture.controller.playbackFailure)
        #expect(failure.kind == .didNotStart)
        #expect(failure.offersRetry)
        #expect(failure.message == PlaybackController.didNotStartMessage)
        #expect(fixture.controller.isPlaying == false)
        let detected = try #require(events(log, .deliveryStallDetected).last)
        #expect(detected.contains("kind=didNotStart"))
        #expect(detected.contains("freeStorage=50000MB"))
        #expect(detected.contains("network=["))
    }

    @Test func lowStorageIsNamedInTheMessage() async throws {
        let (fixture, log) = try await fixture(freeStorage: 300_000_000)
        defer { fixture.cleanUp() }
        await flicker(fixture)

        #expect(fixture.controller.playbackFailure?.message == PlaybackController.didNotStartLowStorageMessage)
        #expect(events(log, .deliveryStallDetected).last?.contains("freeStorage=300MB") == true)
    }

    @Test func aBriefPlayingReportIsNotAFailure() async throws {
        let (fixture, _) = try await fixture()
        defer { fixture.cleanUp() }
        fixture.player.playbackStatus = .paused
        await fixture.controller.samplePlayback(now: .now + 1)

        #expect(fixture.controller.playbackFailure == nil)
    }

    @Test func pausingFromOverplayIsNotAFailure() async throws {
        let (fixture, _) = try await fixture()
        defer { fixture.cleanUp() }
        await fixture.controller.samplePlayback(now: .now + 3)
        fixture.controller.pause()
        await fixture.controller.samplePlayback(now: .now + 4)

        #expect(fixture.controller.playbackFailure == nil)
    }

    @Test func pausingElsewhereAfterProgressIsNotAFailure() async throws {
        let (fixture, _) = try await fixture()
        defer { fixture.cleanUp() }
        await fixture.listen(seconds: 3)
        fixture.player.playbackStatus = .paused
        await fixture.controller.samplePlayback(now: .now + 5)

        #expect(fixture.controller.playbackFailure == nil)
    }

    @Test func anInterruptionIsNotAFailure() async throws {
        let (fixture, _) = try await fixture()
        defer { fixture.cleanUp() }
        await fixture.controller.samplePlayback(now: .now + 1)
        fixture.player.playbackStatus = .interrupted
        await fixture.controller.samplePlayback(now: .now + 3)

        #expect(fixture.controller.playbackFailure == nil)
    }

    /// A bare `play()` is what failed, so the next press starts at rung 2.
    @Test func theNextPlayRecoversFromRungTwo() async throws {
        let (fixture, log) = try await fixture()
        defer { fixture.cleanUp() }
        await flicker(fixture)
        let commandsBefore = fixture.player.commands.count

        await fixture.controller.play(context: fixture.context)

        #expect(Array(fixture.player.commands[commandsBefore...]) == ["prepare", "play"])
        #expect(events(log, .playerCallStarted).contains("prepare recovery rung=2"))
        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.player.submitCount == 1)
    }

    @Test func repeatedFailuresReachAFreshQueueThenAdviseRelaunching() async throws {
        let (fixture, _) = try await fixture()
        defer { fixture.cleanUp() }
        await flicker(fixture)
        await fixture.controller.play(context: fixture.context)
        await flicker(fixture)
        #expect(fixture.controller.playbackFailure?.message == PlaybackController.didNotStartMessage)

        await fixture.controller.play(context: fixture.context)
        #expect(fixture.player.submitCount == 2)
        #expect(fixture.player.submittedStartIndices.last == 1)

        await flicker(fixture)
        let failure = try #require(fixture.controller.playbackFailure)
        #expect(failure.kind == .didNotStart)
        #expect(failure.message == PlaybackController.stillNotStartingMessage)
        #expect(failure.offersRetry)
    }

    @Test func progressAfterAFailureClearsIt() async throws {
        let (fixture, _) = try await fixture()
        defer { fixture.cleanUp() }
        await flicker(fixture)
        // Play pressed on another surface, and this time audio arrives.
        fixture.player.playbackStatus = .playing
        await fixture.listen(seconds: 2)

        #expect(fixture.controller.playbackFailure == nil)
    }

    @Test func eachStatusChangeIsLogged() async throws {
        let (fixture, log) = try await fixture()
        defer { fixture.cleanUp() }
        await flicker(fixture)

        let statuses = events(log, .playerStatusObserved)
        #expect(statuses.contains { $0.hasPrefix("status=playing") })
        #expect(statuses.last?.hasPrefix("status=paused") == true)
    }
}
