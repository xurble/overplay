import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// What happens when a start, a recovery or an observation overlaps something
/// else: findings PB-1 to PB-5 of the 2026-11-11 review. A player call that
/// never returns is the 2026-10-09 failure mode, so most of these hold one
/// open with a gate.
@MainActor
@Suite("Playback overlaps", .serialized)
struct PlaybackOverlapTests {
    /// Holds each caller after the first `passing` until opened.
    final class Gate {
        private var held: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        var passing: Int
        var waiting: Int { held.count }
        init(passing: Int = 0) { self.passing = passing }

        func wait() async {
            guard !isOpen else { return }
            guard passing == 0 else {
                passing -= 1
                return
            }
            await withCheckedContinuation { held.append($0) }
        }

        func open() {
            isOpen = true
            let continuations = held
            held = []
            continuations.forEach { $0.resume() }
        }
    }

    private func fixture(trackCount: Int = 3, player: FakePlaybackPlayer = FakePlaybackPlayer()) throws -> (PlaybackFixture, MusicKitActivityLog) {
        let fixture = try PlaybackFixture(trackCount: trackCount, player: player)
        let log = MusicKitActivityLog(fileURL: nil)
        fixture.controller.activityLog = log
        fixture.controller.startHoldLimit = .seconds(30)
        fixture.controller.stuckCallLimit = .seconds(30)
        return (fixture, log)
    }

    private func select(_ fixture: PlaybackFixture, _ index: Int) async {
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[index],
                                              settings: fixture.settings, context: fixture.context)
    }

    private func shuffleAndPlay(_ fixture: PlaybackFixture) async {
        await fixture.controller.playPlaylist(fixture.playlist, settings: fixture.settings, context: fixture.context)
    }

    private func stall(_ fixture: PlaybackFixture) async {
        for _ in 0...PlaybackController.stallSampleThreshold { await fixture.controller.samplePlayback() }
    }

    private func events(_ log: MusicKitActivityLog, _ operation: MusicKitActivityOperation) -> [String] {
        log.snapshot().events.filter { $0.operation == operation }.compactMap(\.detail)
    }

    /// Records a failure, and carries on so a broken guard cannot hang the run.
    private func waitUntil(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    /// Puts the controller's limits on a clock only the test moves (TST-8).
    private func manualClock(_ fixture: PlaybackFixture) -> ManualPlaybackClock {
        let clock = ManualPlaybackClock()
        fixture.controller.clock = clock.clock
        return clock
    }

    /// Once `sleepers` limits of `duration` have started, moves the clock on
    /// by it. Each limit's watchdog has decided when this returns.
    private func advance(_ clock: ManualPlaybackClock, by duration: Duration, sleepers: Int = 1,
                         sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await waitUntil({ clock.pending(duration) >= sleepers }, sourceLocation: sourceLocation)
        await clock.advance(by: duration)
    }

    // MARK: - PB-1: a hung player call must not stop observation

    @Test(arguments: [false, true])
    func aHungSkipOnReachDoesNotStopObservation(whilePaused: Bool) async throws {
        let (fixture, _) = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 0)
        try fixture.controller.retireTrack(try fixture.item(1), playlist: fixture.playlist,
                                           message: "Retired", context: fixture.context)
        if whilePaused {
            fixture.player.playbackStatus = .paused
            await fixture.player.notify()
        }
        let skip = Gate()
        fixture.player.onNext = { await skip.wait() }

        var delivered = false
        let delivery = Task {
            await fixture.player.externallyAdvance()
            delivered = true
        }
        try await waitUntil { delivered }
        #expect(skip.waiting == 1)

        // Later changes are still seen while the skip has not answered.
        fixture.player.playbackStatus = whilePaused ? .playing : .paused
        await fixture.player.notify()
        #expect(fixture.controller.isPlaying == whilePaused)

        skip.open()
        await delivery.value
        try await waitUntil { fixture.controller.currentTrack?.title == "Song 2" }
        #expect(fixture.player.commands.filter { $0 == "next" }.count == 1)
    }

    @Test func aHungSkipOnReachDoesNotStopTheSampleLoop() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 0)
        try fixture.controller.retireTrack(try fixture.item(1), playlist: fixture.playlist,
                                           message: "Retired", context: fixture.context)
        let skip = Gate()
        fixture.player.onNext = { await skip.wait() }
        fixture.player.silentlyAdvance(to: 0)

        var sampled = false
        let sample = Task {
            await fixture.controller.samplePlayback()
            sampled = true
        }
        try await waitUntil { sampled }
        #expect(skip.waiting == 1)
        skip.open()
        await sample.value
        // The skip finishes beside the sample; let it, before the store goes.
        try await waitUntil { fixture.controller.currentTrack?.title == "Song 2" }
    }

    /// The 2026-11-11 03:48 test-host crash: a skip on reach answered after its
    /// test had returned, and its observation read the current item of a
    /// store the test had released ("destroyed by calling ModelContext.reset",
    /// in `updateRetentionLease`). The app's store lives for the process.
    @Test func aSkipOnReachAnsweredAfterItsTestReturnsFindsTheStoreAlive() async throws {
        let skip = Gate()
        let controller: PlaybackController
        do {
            let (fixture, _) = try fixture()
            defer { fixture.cleanUp() }
            await select(fixture, 0)
            try fixture.controller.retireTrack(try fixture.item(1), playlist: fixture.playlist,
                                               message: "Retired", context: fixture.context)
            fixture.player.onNext = { await skip.wait() }
            await fixture.player.externallyAdvance()
            #expect(skip.waiting == 1)
            controller = fixture.controller
        }
        // The test's store would be released by now: the main run loop drains
        // what the fixture left behind. The skip answers afterwards, as it did
        // after `aHungSkipOnReachDoesNotStopTheSampleLoop` returned.
        try await Task.sleep(for: .milliseconds(200))
        skip.open()
        try await waitUntil { controller.currentTrack?.title == "Song 2" }
        #expect(controller.currentPlaylistItem?.isDeleted == false)
    }

    private func playingUnpreparedQueue(_ fixture: PlaybackFixture) async {
        await select(fixture, 0)
        fixture.player.playbackStatus = .playing
        await fixture.player.notify()
    }

    @Test func aHungUnpreparedQueueRepairDoesNotStopObservation() async throws {
        let player = FakePlaybackPlayer()
        player.prepareFailuresRemaining = 1
        let (fixture, log) = try fixture(player: player)
        defer { fixture.cleanUp() }
        let clock = manualClock(fixture)
        await playingUnpreparedQueue(fixture)
        fixture.controller.startHoldLimit = .milliseconds(50)
        let prepare = Gate()
        fixture.player.onPrepare = { await prepare.wait() }

        var delivered = false
        let delivery = Task {
            await fixture.player.externallyAdvance()
            delivered = true
        }
        try await waitUntil { delivered }
        #expect(prepare.waiting == 1)
        #expect(fixture.player.submitCount == 2)

        // Its hold ends at the limit, and the player is observed again.
        try await advance(clock, by: .milliseconds(50))
        #expect(events(log, .playbackSelectionPath).contains("startTimedOut"))
        fixture.player.playbackStatus = .playing
        await fixture.player.notify()
        #expect(fixture.controller.isPlaying)

        prepare.open()
        await delivery.value
        // The repair finishes beside the delivery; let it, before the store goes.
        try await waitUntil { !fixture.controller.isStartingPlayback }
    }

    @Test func aRepairPublishesWhatThePlayerIsDoingOnceItFinishes() async throws {
        // Changes during the repair's hold are not observed, so nothing else
        // would report the rebuilt queue playing.
        let player = FakePlaybackPlayer()
        player.prepareFailuresRemaining = 1
        let (fixture, _) = try fixture(player: player)
        defer { fixture.cleanUp() }
        await playingUnpreparedQueue(fixture)

        await fixture.player.externallyAdvance()

        #expect(fixture.player.submitCount == 2)
        #expect(fixture.controller.isPlaying)
        #expect(fixture.controller.hasLiveQueue)
    }

    // MARK: - PB-2: a repeat tap during a start

    @Test(arguments: [false, true])
    func aRepeatRowTapDuringAStartLeavesItAlone(reportsPlayingWhileLoading: Bool) async throws {
        let (fixture, _) = try fixture(trackCount: 4)
        defer { fixture.cleanUp() }
        let prepare = Gate()
        fixture.player.onPrepare = {
            if reportsPlayingWhileLoading { fixture.player.playbackStatus = .playing }
            await prepare.wait()
        }
        let first = Task { await select(fixture, 2) }
        try await waitUntil { prepare.waiting == 1 }
        let commandsBefore = fixture.player.commands

        await select(fixture, 2)

        #expect(fixture.player.commands == commandsBefore)
        prepare.open()
        await first.value
        #expect(fixture.player.submitCount == 1)
        #expect(fixture.player.playCount == 1)
        #expect(fixture.player.commands.last == "play")
        #expect(fixture.controller.currentTrack?.title == "Song 2")
    }

    @Test(arguments: [false, true])
    func aRepeatShuffleAndPlayDuringAStartLeavesItAlone(reportsPlayingWhileLoading: Bool) async throws {
        let (fixture, _) = try fixture(trackCount: 4)
        defer { fixture.cleanUp() }
        let prepare = Gate()
        fixture.player.onPrepare = {
            if reportsPlayingWhileLoading { fixture.player.playbackStatus = .playing }
            await prepare.wait()
        }
        let first = Task { await shuffleAndPlay(fixture) }
        try await waitUntil { prepare.waiting == 1 }
        let commandsBefore = fixture.player.commands

        await shuffleAndPlay(fixture)

        #expect(fixture.player.commands == commandsBefore)
        prepare.open()
        await first.value
        #expect(fixture.player.submitCount == 1)
        #expect(Array(fixture.player.commands.suffix(4)) == ["shuffle=off", "shuffle=songs", "next", "play"])
        #expect(fixture.player.playCount == 1)
    }

    @Test func shuffleAndPlayDuringARowStartIsAppliedOnceItLoads() async throws {
        // Not a repeat: the start in flight was not going to shuffle.
        let (fixture, _) = try fixture(trackCount: 4)
        defer { fixture.cleanUp() }
        let prepare = Gate()
        fixture.player.onPrepare = { await prepare.wait() }
        let first = Task { await select(fixture, 2) }
        try await waitUntil { prepare.waiting == 1 }
        let commandsBefore = fixture.player.commands

        await shuffleAndPlay(fixture)

        #expect(fixture.player.commands == commandsBefore)
        prepare.open()
        await first.value
        #expect(fixture.player.submitCount == 1)
        #expect(Array(fixture.player.commands.suffix(3)) == ["shuffle=off", "shuffle=songs", "play"])
        #expect(fixture.controller.shuffleEnabled)
        #expect(fixture.controller.currentTrack?.title == "Song 2")
    }

    @Test func aRepeatShuffleTapDoesNotCarryIntoTheNextStart() async throws {
        let (fixture, _) = try fixture(trackCount: 4)
        defer { fixture.cleanUp() }
        let prepare = Gate()
        fixture.player.onPrepare = { await prepare.wait() }
        let first = Task { await shuffleAndPlay(fixture) }
        try await waitUntil { prepare.waiting == 1 }
        await shuffleAndPlay(fixture)
        prepare.open()
        await first.value
        await fixture.controller.setShuffleEnabled(false, context: fixture.context)
        await fixture.listen(seconds: 10)
        await fixture.player.abandonQueue()
        let commandsBefore = fixture.player.commands.count

        await fixture.controller.play(context: fixture.context)

        #expect(fixture.player.submitCount == 2)
        #expect(!fixture.player.commands[commandsBefore...].contains { $0.hasPrefix("shuffle=") })
    }

    @Test func aPlayPressAfterARepeatTapStillTakesOverTheStart() async throws {
        let (fixture, _) = try fixture(trackCount: 4)
        defer { fixture.cleanUp() }
        let prepare = Gate()
        fixture.player.onPrepare = { await prepare.wait() }
        let first = Task { await select(fixture, 2) }
        try await waitUntil { prepare.waiting == 1 }
        await select(fixture, 2)
        #expect(fixture.player.playCount == 0)

        await fixture.controller.play(context: fixture.context)

        #expect(fixture.player.playCount == 1)
        #expect(fixture.controller.isPlaying)
        prepare.open()
        await first.value
        #expect(fixture.player.playCount == 1)
    }

    @Test func aRepeatTapAfterTheHoldHasEndedIsAPlayAgain() async throws {
        let (fixture, log) = try fixture(trackCount: 4)
        defer { fixture.cleanUp() }
        let clock = manualClock(fixture)
        fixture.controller.startHoldLimit = .milliseconds(50)
        let prepare = Gate()
        fixture.player.onPrepare = { await prepare.wait() }
        let first = Task { await select(fixture, 2) }
        try await waitUntil { prepare.waiting == 1 }
        try await advance(clock, by: .milliseconds(50))
        #expect(events(log, .playbackSelectionPath).contains("startTimedOut"))

        await select(fixture, 2)

        #expect(fixture.player.playCount == 1)
        prepare.open()
        await first.value
    }

    // MARK: - PB-3: only a start that reached play() settles the failure

    @Test func aStartThatTimesOutKeepsItsFailure() async throws {
        let (fixture, log) = try fixture()
        defer { fixture.cleanUp() }
        let clock = manualClock(fixture)
        fixture.controller.startHoldLimit = .milliseconds(50)
        fixture.controller.stuckCallLimit = .milliseconds(50)
        let prepare = Gate()
        fixture.player.onPrepare = { await prepare.wait() }
        let starting = Task { await select(fixture, 0) }
        try await waitUntil { prepare.waiting == 1 }
        try await advance(clock, by: .milliseconds(50), sleepers: 2)
        #expect(fixture.controller.playbackFailure?.kind == .stuck)
        #expect(events(log, .playbackSelectionPath).contains("startTimedOut"))

        prepare.open()
        await starting.value

        #expect(fixture.player.playCount == 0)
        #expect(fixture.controller.playbackFailure?.kind == .command)
        #expect(fixture.controller.statusMessage == PlaybackController.notRespondingMessage)
    }

    @Test func aResumeThatTimesOutDoesNotSeek() async throws {
        let (fixture, log) = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 1)
        await fixture.listen(seconds: 40)
        await fixture.player.abandonQueue()
        let clock = manualClock(fixture)
        fixture.controller.startHoldLimit = .milliseconds(50)
        let prepare = Gate()
        fixture.player.onPrepare = { await prepare.wait() }
        let playsBefore = fixture.player.playCount

        let press = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { prepare.waiting == 1 && clock.pending(.milliseconds(50)) == 1 }
        await clock.advance(by: .milliseconds(49))
        #expect(!events(log, .playbackSelectionPath).contains("startTimedOut"))
        await clock.advance(by: .milliseconds(1))
        #expect(events(log, .playbackSelectionPath).contains("startTimedOut"))
        prepare.open()
        await press.value

        #expect(fixture.player.playCount == playsBefore)
        #expect(fixture.player.playbackTime == 0)
        #expect(fixture.controller.playbackFailure != nil)
    }

    @Test func aStartThatPlaysStillClearsTheFailureAndSeeks() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 1)
        await fixture.listen(seconds: 40)
        await fixture.player.abandonQueue()
        #expect(fixture.controller.playbackFailure != nil)

        await fixture.controller.play(context: fixture.context)

        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.player.playbackTime == 40)
    }

    /// Where the Play press lands in the start, each a different early return.
    enum StartStage: CaseIterable, Sendable { case preparing, loading, shuffleSkip }

    @Test(arguments: StartStage.allCases)
    func aFailedPlayPressDuringAStartKeepsItsFailure(stage: StartStage) async throws {
        let (fixture, _) = try fixture(trackCount: 4)
        defer { fixture.cleanUp() }
        fixture.controller.queueLoadLimit = .seconds(30)
        let gate = Gate()
        switch stage {
        case .preparing:
            fixture.player.onPrepare = { await gate.wait() }
        case .loading:
            fixture.player.loadsEntriesInSteps = 1
            fixture.player.stopsLoading = true
        case .shuffleSkip:
            fixture.player.onNext = { await gate.wait() }
        }
        let starting = Task {
            if stage == .shuffleSkip {
                await shuffleAndPlay(fixture)
            } else {
                await select(fixture, 0)
            }
        }
        switch stage {
        case .preparing, .shuffleSkip: try await waitUntil { gate.waiting == 1 }
        case .loading: try await waitUntil { fixture.player.commands.contains("prepare") }
        }
        fixture.player.playFailuresRemaining = 1

        await fixture.controller.play(context: fixture.context)
        #expect(fixture.controller.playbackFailure?.kind == .command)

        gate.open()
        await starting.value
        #expect(fixture.controller.playbackFailure?.kind == .command)
    }

    // MARK: - PB-3: a Play press that takes over a resume

    /// Song 1 at 0:40, its queue lost while paused: Play resumes with no failure.
    private func songLostWhilePaused(_ fixture: PlaybackFixture) async {
        await select(fixture, 1)
        await fixture.listen(seconds: 40)
        fixture.player.playbackStatus = .paused
        await fixture.player.notify()
        await fixture.player.abandonQueue()
    }

    /// Presses Play, then presses it again while the resume's prepare is held.
    private func pressPlayDuringResume(_ fixture: PlaybackFixture, prepare: Gate) async throws -> Task<Void, Never> {
        fixture.player.onPrepare = { await prepare.wait() }
        let resuming = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { prepare.waiting == 1 }
        await fixture.controller.play(context: fixture.context)
        return resuming
    }

    @Test func playDuringAResumeKeepsTheSongAndPosition() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.cleanUp() }
        await songLostWhilePaused(fixture)
        let playsBefore = fixture.player.playCount
        let prepare = Gate()

        let resuming = try await pressPlayDuringResume(fixture, prepare: prepare)
        #expect(fixture.player.playCount == playsBefore + 1)
        prepare.open()
        await resuming.value

        #expect(fixture.player.playbackTime == 40)
        #expect(fixture.controller.elapsedSeconds == 40)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        #expect(fixture.controller.isPlaying)
        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.player.submitCount == 2)
        #expect(fixture.player.playCount == playsBefore + 1)
        let resume = try #require(fixture.intentStore.loadResumePoint())
        #expect(resume.localTrackID == fixture.tracks[1].id.uuidString)
        #expect(resume.positionSeconds == 40)
    }

    @Test(arguments: [false, true])
    func aTakeoverDoesNotSeekWhenThePlayerHasMovedToAnotherSong(observed: Bool) async throws {
        let (fixture, _) = try fixture()
        defer { fixture.cleanUp() }
        await songLostWhilePaused(fixture)
        let prepare = Gate()
        let resuming = try await pressPlayDuringResume(fixture, prepare: prepare)

        fixture.player.silentlyAdvance(to: 7)
        if observed {
            // Paused, or this song change would rebuild the unprepared queue.
            fixture.player.playbackStatus = .paused
            await fixture.player.notify()
        }
        prepare.open()
        await resuming.value

        #expect(fixture.player.playbackTime == 7)
        #expect(fixture.controller.currentTrack?.title == "Song 2")
    }

    @Test func aFailedPlayPressDuringAResumeKeepsItsFailureAndThePosition() async throws {
        let (fixture, _) = try fixture()
        defer { fixture.cleanUp() }
        await songLostWhilePaused(fixture)
        let prepare = Gate()
        fixture.player.playFailuresRemaining = 1

        let resuming = try await pressPlayDuringResume(fixture, prepare: prepare)
        #expect(fixture.controller.playbackFailure?.kind == .command)
        prepare.open()
        await resuming.value

        #expect(fixture.controller.playbackFailure?.kind == .command)
        #expect(fixture.player.playbackTime == 40)
    }

    @Test func aTakeoverWhosePrepareAnswersPastTheLimitDoesNotJump() async throws {
        let (fixture, log) = try fixture()
        defer { fixture.cleanUp() }
        await songLostWhilePaused(fixture)
        let clock = manualClock(fixture)
        fixture.controller.startHoldLimit = .milliseconds(50)
        let prepare = Gate()
        let resuming = try await pressPlayDuringResume(fixture, prepare: prepare)
        try await advance(clock, by: .milliseconds(50))
        #expect(events(log, .playbackSelectionPath).contains("startTakeoverExpired"))

        // The song has been playing from the top meanwhile.
        fixture.player.playbackTime = 30
        prepare.open()
        await resuming.value

        #expect(fixture.player.playbackTime == 30)
    }

    @Test(arguments: [false, true])
    func aHoldLostDuringTheFinalPlayOnlySeeksTheSameSong(movedOn: Bool) async throws {
        let (fixture, log) = try fixture()
        defer { fixture.cleanUp() }
        await songLostWhilePaused(fixture)
        let clock = manualClock(fixture)
        fixture.controller.startHoldLimit = .milliseconds(50)
        let play = Gate()
        fixture.player.onPlay = { await play.wait() }

        let resuming = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { play.waiting == 1 }
        try await advance(clock, by: .milliseconds(50))
        #expect(events(log, .playbackSelectionPath).contains("startTimedOut"))
        if movedOn { fixture.player.silentlyAdvance(to: 7) }
        play.open()
        await resuming.value

        #expect(fixture.player.playbackTime == (movedOn ? 7 : 40))
        #expect(fixture.controller.currentTrack?.title == (movedOn ? "Song 2" : "Song 1"))
        #expect(fixture.controller.playbackFailure == nil)
    }

    @Test func aStartThatPlaysAfterItsHoldEndedStillClearsTheFailure() async throws {
        let (fixture, log) = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 1)
        await fixture.listen(seconds: 40)
        await fixture.player.abandonQueue()
        #expect(fixture.controller.playbackFailure != nil)
        let clock = manualClock(fixture)
        fixture.controller.startHoldLimit = .milliseconds(50)
        let play = Gate()
        fixture.player.onPlay = { await play.wait() }

        // Play recovers with a fresh queue, whose final play() outlasts the hold.
        let starting = Task { await fixture.controller.play(context: fixture.context) }
        try await waitUntil { play.waiting == 1 }
        try await advance(clock, by: .milliseconds(50))
        #expect(events(log, .playbackSelectionPath).contains("startTimedOut"))
        play.open()
        await starting.value

        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.controller.statusMessage == nil)
    }

    // MARK: - PB-4: network return

    @Test func aHungNetworkRecoveryDoesNotLatchOffLaterReturns() async throws {
        let prepare = Gate(passing: 1)
        let player = FakePlaybackPlayer()
        player.onPrepare = { await prepare.wait() }
        let (fixture, log) = try fixture(player: player)
        defer { fixture.cleanUp() }
        fixture.controller.networkSettleDelay = .zero
        await select(fixture, 0)
        await stall(fixture)
        #expect(fixture.controller.playbackFailure?.kind == .stalled)

        let firstReturn = Task { await fixture.controller.networkReturned() }
        try await waitUntil { prepare.waiting == 1 }

        // Its rung 2 hangs. The next return escalates to a fresh queue.
        prepare.passing = 1
        await fixture.controller.networkReturned()

        #expect(events(log, .playbackRecoveryAttempt) == ["network returned", "network returned"])
        #expect(fixture.player.submitCount == 2)
        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.controller.isPlaying)

        // The hung run answers late and leaves the newer queue alone.
        let commandsBefore = fixture.player.commands
        prepare.open()
        await firstReturn.value
        #expect(fixture.player.commands == commandsBefore)
        #expect(fixture.controller.playbackFailure == nil)
    }

    @Test func aBurstOfPathUpdatesRunsOneRecovery() async throws {
        // The recovery is held open: one that finished at once would clear the
        // failure, and a second run would stop for that reason instead.
        let prepare = Gate(passing: 1)
        let player = FakePlaybackPlayer()
        player.onPrepare = { await prepare.wait() }
        let (fixture, log) = try fixture(player: player)
        defer { fixture.cleanUp() }
        let clock = manualClock(fixture)
        fixture.controller.networkSettleDelay = .milliseconds(200)
        await select(fixture, 0)
        await stall(fixture)

        let first = Task { await fixture.controller.networkReturned() }
        try await waitUntil { clock.pending(.milliseconds(200)) == 1 }
        // The second update arrives while the first settles: it returns at
        // once, or, unguarded, settles alongside.
        var secondReturned = false
        let second = Task {
            await fixture.controller.networkReturned()
            secondReturned = true
        }
        try await waitUntil { secondReturned || clock.pending(.milliseconds(200)) == 2 }
        #expect(events(log, .playbackRecoveryAttempt).isEmpty)

        await clock.advance(by: .milliseconds(200))

        #expect(events(log, .playbackRecoveryAttempt) == ["network returned"])
        try await waitUntil { prepare.waiting == 1 }
        #expect(events(log, .playbackRecoveryAttempt) == ["network returned"])

        prepare.open()
        await first.value
        await second.value
    }

    // MARK: - PB-5: a queue lost while paused

    @Test(arguments: [false, true], [false, true])
    func aQueueLostWhilePausedKeepsTheSongAndPosition(stale: Bool, reportsStoppedFirst: Bool) async throws {
        let (fixture, _) = try fixture()
        defer { fixture.cleanUp() }
        await select(fixture, 1)
        await fixture.listen(seconds: 40)
        // From the Lock Screen, so Overplay's own Pause has not saved anything.
        fixture.player.playbackStatus = .paused
        await fixture.player.notify()
        if stale { await fixture.controller.samplePlayback(now: .now.addingTimeInterval(-600)) }
        if reportsStoppedFirst {
            fixture.player.playbackStatus = .stopped
            await fixture.player.notify()
        }

        await fixture.player.abandonQueue()

        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.controller.statusMessage == nil)
        #expect(fixture.controller.currentTrack?.title == "Song 1")
        #expect(fixture.controller.elapsedSeconds == 40)
        let resume = try #require(fixture.intentStore.loadResumePoint())
        #expect(resume.localTrackID == fixture.tracks[1].id.uuidString)
        #expect(resume.positionSeconds == 40)

        await fixture.controller.play(context: fixture.context)
        #expect(fixture.player.submittedStartIndices.last == 1)
        #expect(fixture.player.playbackTime == 40)
    }

    @Test func aPlayerThatPausesAtTheEndOfTheQueueStillEnded() async throws {
        // A natural end may report paused before the queue empties.
        let (fixture, _) = try fixture(trackCount: 2)
        defer { fixture.cleanUp() }
        await select(fixture, 1)
        await fixture.listen(to: 179)
        fixture.player.playbackStatus = .paused
        await fixture.player.notify()

        await fixture.player.abandonQueue()

        #expect(fixture.controller.playbackFailure == nil)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
    }
}
