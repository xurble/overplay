import Foundation
@preconcurrency import MusicKit
import SwiftData
import Testing
@testable import Overplay

/// The device log has to explain a stall after the fact (#84): a player call
/// that never returns, what the controller made of each entry change, and
/// what every surface was shown.
@MainActor
@Suite("Playback diagnostics", .serialized)
struct PlaybackDiagnosticsTests {
    private func fixture(player: FakePlaybackPlayer = FakePlaybackPlayer()) throws -> (PlaybackFixture, MusicKitActivityLog) {
        let fixture = try PlaybackFixture(player: player)
        let log = MusicKitActivityLog(fileURL: nil)
        fixture.controller.activityLog = log
        return (fixture, log)
    }

    private func events(_ log: MusicKitActivityLog, _ operation: MusicKitActivityOperation) -> [String] {
        log.snapshot().events.filter { $0.operation == operation }.compactMap(\.detail)
    }

    @Test func aPrepareThatNeverReturnsIsVisibleAsStartedWithoutCompletion() async throws {
        let player = FakePlaybackPlayer()
        var release: CheckedContinuation<Void, Never>?
        player.onPrepare = { await withCheckedContinuation { release = $0 } }
        let (fixture, log) = try fixture(player: player)
        defer { fixture.cleanUp() }
        fixture.controller.startHoldLimit = .milliseconds(50)

        let start = Task {
            await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                                  settings: fixture.settings, context: fixture.context)
        }
        while release == nil { await Task.yield() }
        // The hold's watchdog gives up on the start; the prepare is still waiting.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !events(log, .playbackSelectionPath).contains("startTimedOut"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(events(log, .playerCallStarted).contains { $0.hasPrefix("prepare start=") })
        #expect(!events(log, .playerCallStarted).contains { $0.hasPrefix("play start=") })
        #expect(events(log, .playbackSelectionPath).contains("startTimedOut"))
        release?.resume()
        await start.value
    }

    @Test func recoveryRecordsEachPlayerCallItWaitsOn() async throws {
        let (fixture, log) = try fixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        for _ in 0..<12 { await fixture.controller.samplePlayback() }
        #expect(fixture.controller.playbackFailure?.kind == .stalled)

        await fixture.controller.play(context: fixture.context)

        #expect(events(log, .playerCallStarted).contains("prepare recovery rung=2"))
        let stall = try #require(events(log, .deliveryStallDetected).first)
        #expect(stall.contains("kind=stalled"))
        #expect(stall.contains("status=playing"))
    }

    @Test func eachEntryChangeRecordsTheItemTheMemberAndTheDisplay() async throws {
        let (fixture, log) = try fixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        await fixture.player.externallyAdvance()

        let entries = events(log, .playerEntryObserved)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.hasPrefix("new entry=") })
        #expect(entries.last?.contains("item=\"Song 1\" member=\"Song 1\"") == true)
        let displays = events(log, .nowPlayingDisplayChanged)
        #expect(displays.contains { $0.hasPrefix("\"Song 0\"") })
        #expect(displays.last?.hasPrefix("\"Song 1\"") == true)
    }

    @Test func anUnattributedEntryIsRecordedAsShownWithoutAMember() async throws {
        let (fixture, log) = try fixture()
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        fixture.player.replaceItem(at: 1, with: PlayerItemSnapshot(
            id: "x", identifiers: ["x"], title: "Stranger", artistName: "Elsewhere",
            albumTitle: nil, artworkURLTemplate: nil, durationSeconds: 200))
        await fixture.player.externallyAdvance()

        #expect(events(log, .playerEntryObserved).last?.contains("item=\"Stranger\" member=none") == true)
        #expect(events(log, .nowPlayingDisplayChanged).last?.hasSuffix("member=false") == true)
    }

    @Test func lateHydrationIsRecorded() async throws {
        let player = FakePlaybackPlayer()
        player.hydratesOnSubmit = false
        let (fixture, log) = try fixture(player: player)
        defer { fixture.cleanUp() }
        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)
        #expect(events(log, .playerEntryObserved).last?.contains("item=unhydrated") == true)

        fixture.player.hydrateAll()
        await fixture.player.notify()

        #expect(events(log, .playerEntryObserved).last?.hasPrefix("hydrated entry=") == true)
    }

    @Test func observationHeldDuringAStartIsListedOnce() async throws {
        let player = FakePlaybackPlayer()
        let (fixture, log) = try fixture(player: player)
        defer { fixture.cleanUp() }
        player.onPrepare = { [controller = fixture.controller] in
            await controller.observePlayer()
            await controller.observePlayer()
        }

        await fixture.controller.playPlaylist(fixture.playlist, startingAt: fixture.tracks[0],
                                              settings: fixture.settings, context: fixture.context)

        #expect(events(log, .observationHeld).count == 1)
        #expect(fixture.controller.currentTrack?.title == "Song 0")
    }

    @Test func theLogKeepsAThousandEvents() {
        let log = MusicKitActivityLog(fileURL: nil)
        for index in 0..<1_100 { log.record(.playerEntryObserved, detail: "\(index)") }
        let details = log.snapshot().events.compactMap(\.detail)
        #expect(details.count == 1_000)
        #expect(details.first == "100")
    }
}
