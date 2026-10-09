import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// A player call that never returns (#84). On 2026-10-09 a `prepareToPlay`
/// hung, every Play press repeated recovery rung 2 on the same hung player,
/// and only relaunching Overplay recovered. The ladder must escalate past a
/// hung rung, and a stuck player must be told apart, given one fresh queue,
/// and then sent nothing more.
@MainActor
@Suite("Stuck player recovery", .serialized)
struct StuckPlayerRecoveryTests {
    /// Holds every prepare after the first `passing` until released. Once
    /// released, later prepares pass, so a broken guard fails a test rather
    /// than hanging it.
    final class HungPrepares {
        private(set) var waiting: [CheckedContinuation<Void, Never>] = []
        var passing: Int
        private var isReleased = false
        init(passing: Int = 0) { self.passing = passing }

        func install(on player: FakePlaybackPlayer) {
            player.onPrepare = { [self] in
                guard !isReleased else { return }
                guard passing == 0 else {
                    passing -= 1
                    return
                }
                await withCheckedContinuation { waiting.append($0) }
            }
        }

        func releaseAll() {
            isReleased = true
            let continuations = waiting
            waiting = []
            continuations.forEach { $0.resume() }
        }
    }

    private func fixture(hung: HungPrepares) throws -> (PlaybackFixture, MusicKitActivityLog) {
        let player = FakePlaybackPlayer()
        hung.install(on: player)
        let fixture = try PlaybackFixture(player: player)
        let log = MusicKitActivityLog(fileURL: nil)
        fixture.controller.activityLog = log
        return (fixture, log)
    }

    private func start(_ fixture: PlaybackFixture) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
    }

    private func stall(_ fixture: PlaybackFixture) async {
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
    }

    private func events(_ log: MusicKitActivityLog, _ operation: MusicKitActivityOperation) -> [String] {
        log.snapshot().events.filter { $0.operation == operation }.compactMap(\.detail)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    // MARK: - Escalation past a hung rung

    @Test func aPressWhileRungTwoHangsEscalatesToRungThree() async throws {
        // The start's prepare passes; rung 2's hangs; rung 3's passes.
        let hung = HungPrepares(passing: 1)
        let (fixture, log) = try fixture(hung: hung)
        defer { fixture.cleanUp() }
        await start(fixture)
        await stall(fixture)
        #expect(fixture.controller.playbackFailure?.kind == .stalled)

        let firstPress = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { hung.waiting.count == 1 }
        hung.passing = 1
        await fixture.controller.play(context: fixture.context)

        #expect(events(log, .playerCallStarted).filter { $0 == "prepare recovery rung=2" }.count == 1)
        #expect(fixture.player.submitCount == 2)
        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.controller.isPlaying)

        // The hung rung 2 returns late; the newer queue is left alone.
        let commandsBefore = fixture.player.commands
        hung.releaseAll()
        await firstPress.value
        #expect(fixture.player.commands == commandsBefore)
        #expect(fixture.controller.playbackFailure == nil)
    }

    // MARK: - Stuck

    @Test func aCallUnansweredAtTheLimitMakesThePlayerStuck() async throws {
        let hung = HungPrepares()
        let (fixture, log) = try fixture(hung: hung)
        defer { fixture.cleanUp() }
        fixture.controller.stuckCallLimit = .milliseconds(50)
        fixture.controller.startHoldLimit = .milliseconds(50)

        let starting = Task { await start(fixture) }
        try await waitUntil { fixture.controller.playbackFailure?.kind == .stuck }

        let failure = try #require(fixture.controller.playbackFailure)
        #expect(failure.message == PlaybackController.stuckMessage)
        #expect(!failure.offersRetry)
        #expect(fixture.controller.statusMessage == PlaybackController.stuckMessage)
        #expect(events(log, .playerCallStuck).contains { $0.hasPrefix("prepare start=") })

        // Once the call returns, the advice to relaunch goes away.
        hung.releaseAll()
        await starting.value
        #expect(fixture.controller.playbackFailure?.kind != .stuck)
        #expect(fixture.controller.statusMessage != PlaybackController.stuckMessage)
        #expect(events(log, .playerCallStuck).contains { $0.contains("answered late") })
    }

    @Test func aStuckPlayerGetsOneFreshQueueThenNoMoreCalls() async throws {
        let hung = HungPrepares()
        let (fixture, log) = try fixture(hung: hung)
        defer { fixture.cleanUp() }
        fixture.controller.stuckCallLimit = .milliseconds(50)
        fixture.controller.startHoldLimit = .milliseconds(50)
        let starting = Task { await start(fixture) }
        try await waitUntil { fixture.controller.playbackFailure?.kind == .stuck }

        // The first press skips straight to a fresh queue: preparing the hung
        // queue again would only stack another call on it.
        let firstPress = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { hung.waiting.count == 2 }
        #expect(fixture.player.submitCount == 2)
        #expect(events(log, .playerCallStarted).allSatisfy { !$0.contains("rung=") })

        // That queue hangs too. Later presses send nothing.
        try await Task.sleep(for: .milliseconds(100))
        let commandsBefore = fixture.player.commands
        let laterPresses = Task {
            await fixture.controller.play(context: fixture.context)
            await fixture.controller.play(context: fixture.context)
        }
        try await waitUntil { events(log, .playbackRecoveryAttempt).filter { $0.contains("no call made") }.count == 2 }
        #expect(fixture.player.commands == commandsBefore)
        #expect(fixture.controller.playbackFailure?.kind == .stuck)
        #expect(fixture.controller.statusMessage == PlaybackController.stuckMessage)

        hung.releaseAll()
        await laterPresses.value
        await firstPress.value
        await starting.value
    }

    @Test func aMilderFailureWithNoAnswerKeepsTheStuckAdvice() async throws {
        let (fixture, _) = try fixture(hung: HungPrepares(passing: 1))
        defer { fixture.cleanUp() }
        await start(fixture)
        fixture.controller.pause()
        fixture.controller.stuckCallLimit = .milliseconds(50)
        var release: CheckedContinuation<Void, Never>?
        fixture.player.onPlay = { await withCheckedContinuation { release = $0 } }
        let press = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { fixture.controller.playbackFailure?.kind == .stuck }

        // The player drops its queue, which on its own reads "press Play".
        await fixture.player.abandonQueue()

        #expect(fixture.controller.playbackFailure?.kind == .stuck)
        #expect(fixture.controller.statusMessage == PlaybackController.stuckMessage)
        fixture.player.onPlay = nil
        release?.resume()
        await press.value
    }

    @Test func anErrorAnswerReplacesTheStuckAdvice() async throws {
        let hung = HungPrepares()
        let (fixture, _) = try fixture(hung: hung)
        defer { fixture.cleanUp() }
        fixture.controller.stuckCallLimit = .milliseconds(50)
        fixture.controller.startHoldLimit = .milliseconds(50)
        let starting = Task { await start(fixture) }
        try await waitUntil { fixture.controller.playbackFailure?.kind == .stuck }

        // The fresh queue's prepare answers, then its play fails: the player
        // is answering, so its own error is shown and Play is offered.
        hung.passing = 1
        fixture.player.playFailuresRemaining = 1
        await fixture.controller.play(context: fixture.context)

        #expect(fixture.controller.playbackFailure?.kind == .command)
        #expect(fixture.controller.playbackFailure?.offersRetry == true)
        hung.releaseAll()
        await starting.value
    }

    @Test func witnessedProgressClearsAStuckPlayer() async throws {
        let hung = HungPrepares(passing: 1)
        let (fixture, _) = try fixture(hung: hung)
        defer { fixture.cleanUp() }
        fixture.controller.stuckCallLimit = .milliseconds(50)
        await start(fixture)
        await stall(fixture)
        let press = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { fixture.controller.playbackFailure?.kind == .stuck }

        // MusicKit plays after all: the player is no longer stuck.
        for _ in 0..<2 {
            fixture.player.playbackTime += 1
            await fixture.controller.samplePlayback()
        }
        #expect(fixture.controller.playbackFailure == nil)

        hung.releaseAll()
        await press.value
        #expect(fixture.controller.playbackFailure == nil)
    }

    // MARK: - Review fixes

    @Test func aSupersededCallDoesNotMarkAnAnsweringPlayerStuck() async throws {
        // The start passes; rung 2 hangs; the next press's rung 3 plays.
        let hung = HungPrepares(passing: 1)
        let (fixture, log) = try fixture(hung: hung)
        defer { fixture.cleanUp() }
        fixture.controller.stuckCallLimit = .milliseconds(100)
        await start(fixture)
        await stall(fixture)
        let firstPress = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { hung.waiting.count == 1 }
        hung.passing = 1
        await fixture.controller.play(context: fixture.context)
        #expect(fixture.controller.playbackFailure == nil)

        // Rung 2's limit passes while the new queue plays.
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.controller.playbackFailure == nil)
        #expect(events(log, .playerCallStuck).isEmpty)
        hung.releaseAll()
        await firstPress.value
    }

    @Test func aRungThatAnswersLateEndsThePressWithoutClimbing() async throws {
        let hung = HungPrepares()
        let (fixture, _) = try fixture(hung: hung)
        defer { fixture.cleanUp() }
        hung.passing = 1
        fixture.player.playFailuresRemaining = 1
        await start(fixture)
        #expect(fixture.controller.playbackFailure?.kind == .command)
        // Later prepares pass, so a ladder that wrongly climbs shows up as
        // extra commands rather than a hang.
        hung.releaseAll()

        // Rung 1's play hangs past the limit, then fails.
        fixture.controller.stuckCallLimit = .milliseconds(50)
        var release: CheckedContinuation<Void, Never>?
        fixture.player.onPlay = { await withCheckedContinuation { release = $0 } }
        let press = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { fixture.controller.playbackFailure?.kind == .stuck }
        fixture.player.onPlay = nil
        fixture.player.playFailuresRemaining = 1
        let commandsBefore = fixture.player.commands
        release?.resume()
        await press.value

        // No rung 2 or 3 ran by itself; Play is offered again.
        #expect(fixture.player.commands == commandsBefore)
        #expect(fixture.controller.playbackFailure?.kind == .command)
        #expect(fixture.controller.playbackFailure?.message == PlaybackController.notRespondingMessage)
    }

    @Test func aHungResumeMarksThePlayerStuck() async throws {
        let (fixture, log) = try fixture(hung: HungPrepares(passing: 1))
        defer { fixture.cleanUp() }
        await start(fixture)
        fixture.controller.pause()
        fixture.controller.stuckCallLimit = .milliseconds(50)
        var release: CheckedContinuation<Void, Never>?
        fixture.player.onPlay = { await withCheckedContinuation { release = $0 } }

        let press = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { fixture.controller.playbackFailure?.kind == .stuck }
        #expect(events(log, .playerCallStuck).contains("play resume unanswered"))
        fixture.player.onPlay = nil
        release?.resume()
        await press.value
        #expect(fixture.controller.playbackFailure?.kind != .stuck)
    }

    @Test func afterALateAnswerPlayCallsThePlayerAgain() async throws {
        let hung = HungPrepares()
        let (fixture, _) = try fixture(hung: hung)
        defer { fixture.cleanUp() }
        fixture.controller.stuckCallLimit = .milliseconds(50)
        fixture.controller.startHoldLimit = .milliseconds(50)
        let starting = Task { await start(fixture) }
        try await waitUntil { fixture.controller.playbackFailure?.kind == .stuck }
        let pressing = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { hung.waiting.count == 2 }
        hung.releaseAll()
        await pressing.value
        await starting.value
        #expect(fixture.controller.playbackFailure?.kind != .stuck)

        // The player answers again, so the next press makes calls.
        let commandsBefore = fixture.player.commands.count
        await fixture.controller.play(context: fixture.context)
        #expect(fixture.player.commands.count > commandsBefore)
    }

    // MARK: - Surfaces

    @Test func surfacesAlertAgainOnlyWhenThePlayerBecomesStuck() {
        #expect(PlaybackFailure.needsAlert(.stalled, alerted: nil))
        #expect(!PlaybackFailure.needsAlert(.command, alerted: .stalled))
        #expect(PlaybackFailure.needsAlert(.stuck, alerted: .stalled))
        #expect(!PlaybackFailure.needsAlert(.stuck, alerted: .stuck))
        // Answering again brings Try Again back.
        #expect(PlaybackFailure.needsAlert(.command, alerted: .stuck))
        #expect(!PlaybackFailure(kind: .stuck, message: "", since: .now).offersRetry)
        #expect(PlaybackFailure(kind: .stalled, message: "", since: .now).offersRetry)
    }

    @Test func networkPathsAreDescribedForTheLog() {
        #expect(NetworkReachabilityMonitor.describe(status: "satisfied", interfaces: ["wifi"],
                                                    isExpensive: false, isConstrained: false)
            == "status=satisfied via=wifi")
        #expect(NetworkReachabilityMonitor.describe(status: "unsatisfied", interfaces: [],
                                                    isExpensive: true, isConstrained: true)
            == "status=unsatisfied via=none expensive constrained")
    }
}
