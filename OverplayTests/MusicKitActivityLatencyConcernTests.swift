import Foundation
import Testing
@testable import Overplay

@Suite("Activity report: degradation and post-mortem reads")
struct MusicKitActivityLatencyConcernTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func event(
        _ operation: MusicKitActivityOperation,
        offsetMinutes: Double,
        milliseconds: Double
    ) -> MusicKitActivityEvent {
        MusicKitActivityEvent(
            operation: operation,
            startedAt: start.addingTimeInterval(offsetMinutes * 60),
            durationMilliseconds: milliseconds
        )
    }

    @Test("a call getting hundreds of times slower is reported")
    func degradingCallIsReported() {
        // The shape of a real session: playlist track fetches at single-digit
        // milliseconds early, seconds later.
        let events = [
            event(.playlistTrackFetch, offsetMinutes: 0, milliseconds: 7),
            event(.playlistTrackFetch, offsetMinutes: 1, milliseconds: 2),
            event(.playlistTrackFetch, offsetMinutes: 2, milliseconds: 8),
            event(.playlistTrackFetch, offsetMinutes: 40, milliseconds: 396),
            event(.playlistTrackFetch, offsetMinutes: 80, milliseconds: 4603),
            event(.playlistTrackFetch, offsetMinutes: 81, milliseconds: 212)
        ]

        let concerns = MusicKitActivityReport.latencyConcerns(
            events: events,
            now: start.addingTimeInterval(90 * 60)
        )

        #expect(concerns.count == 1)
        #expect(concerns.first?.title == "Apple Music is getting slower")
    }

    @Test("a steady call is not reported")
    func steadyCallIsNotReported() {
        let events = (0..<8).map {
            event(.libraryPlaylistLookup, offsetMinutes: Double($0), milliseconds: 4)
        }

        #expect(MusicKitActivityReport.latencyConcerns(events: events, now: start).isEmpty)
    }

    @Test("a small absolute slowdown is not news")
    func smallAbsoluteSlowdownIsNotNews() {
        // 1ms to 20ms is a 20x factor but still far too fast to matter.
        let events = (0..<4).map { event(.libraryPlaylistLookup, offsetMinutes: Double($0), milliseconds: 1) }
            + (0..<4).map { event(.libraryPlaylistLookup, offsetMinutes: Double(10 + $0), milliseconds: 20) }

        #expect(MusicKitActivityReport.latencyConcerns(events: events, now: start).isEmpty)
    }

    @Test("too few samples to judge is not reported")
    func tooFewSamplesIsNotReported() {
        let events = [
            event(.playerPlay, offsetMinutes: 0, milliseconds: 2),
            event(.playerPlay, offsetMinutes: 1, milliseconds: 4000)
        ]

        #expect(MusicKitActivityReport.latencyConcerns(events: events, now: start).isEmpty)
    }

    @Test("a failure burst is still reported once its window has passed")
    func failureBurstSurvivesItsWindow() {
        // The report is read after the fact at least as often as during. A
        // burst that has aged out is exactly what the reader came looking for.
        let failedAt = start
        let events = (0..<10).map { index in
            MusicKitActivityEvent(
                operation: .playerPlay,
                startedAt: failedAt.addingTimeInterval(Double(index)),
                durationMilliseconds: 200,
                errorDomain: "MPMusicPlayerControllerErrorDomain",
                errorCode: 6,
                errorDescription: "The operation couldn't be completed."
            )
        }
        let snapshot = MusicKitActivitySnapshot(
            tallies: [],
            events: events,
            observationStartedAt: start
        )

        let hoursLater = MusicKitActivityReport.summary(
            for: snapshot,
            now: failedAt.addingTimeInterval(4 * 60 * 60)
        )

        let failureConcerns = hoursLater.concerns.filter { $0.title.hasPrefix("Repeated identical failure") }
        #expect(failureConcerns.count == 1)
        #expect(failureConcerns.first?.isActive == false)
        #expect(failureConcerns.first?.severity == .info)
        #expect(!hoursLater.concerns.isEmpty)
    }

    @Test("the same burst reads as active while it is still happening")
    func failureBurstIsActiveWhileHappening() {
        let events = (0..<10).map { index in
            MusicKitActivityEvent(
                operation: .playerPlay,
                startedAt: start.addingTimeInterval(Double(index)),
                durationMilliseconds: 200,
                errorDomain: "MPMusicPlayerControllerErrorDomain",
                errorCode: 6
            )
        }
        let snapshot = MusicKitActivitySnapshot(tallies: [], events: events, observationStartedAt: start)

        let summary = MusicKitActivityReport.summary(
            for: snapshot,
            now: start.addingTimeInterval(60)
        )

        let failureConcern = summary.concerns.first { $0.title.hasPrefix("Repeated identical failure") }
        #expect(failureConcern?.isActive == true)
        #expect(failureConcern?.severity == .warning)
    }
}

@Suite("Activity report: origins and Overplay's own decisions")
struct MusicKitActivityOriginTests {
    private let start = Date(timeIntervalSince1970: 2_000_000)

    @Test("a command's originating surface is recorded and rendered")
    func originIsRecordedAndRendered() {
        let snapshot = MusicKitActivitySnapshot(
            tallies: [],
            events: [
                MusicKitActivityEvent(
                    operation: .playerPlay,
                    startedAt: start,
                    durationMilliseconds: 200,
                    origin: .carPlay
                )
            ],
            observationStartedAt: start
        )

        let text = MusicKitActivityReport.text(
            for: MusicKitActivityReport.summary(for: snapshot, now: start.addingTimeInterval(60))
        )

        // Without this, a retry burst cannot be attributed to the user, to
        // another surface, or to Overplay retrying itself.
        #expect(text.contains("via=carPlay"))
    }

    @Test("Overplay's own playback decisions share the call timeline")
    func playbackDecisionsShareTheTimeline() {
        let snapshot = MusicKitActivitySnapshot(
            tallies: [],
            events: [
                MusicKitActivityEvent(
                    operation: .queueCorrelationCleared,
                    startedAt: start,
                    magnitude: 50,
                    detail: "diverged transition"
                ),
                MusicKitActivityEvent(
                    operation: .deliveryStallDetected,
                    startedAt: start.addingTimeInterval(1),
                    detail: "playback stalled"
                ),
                MusicKitActivityEvent(
                    operation: .queueEndObserved,
                    startedAt: start.addingTimeInterval(2),
                    detail: "no restart"
                )
            ],
            observationStartedAt: start
        )

        let text = MusicKitActivityReport.text(
            for: MusicKitActivityReport.summary(for: snapshot, now: start.addingTimeInterval(60))
        )

        // Interleaved with the Apple Music calls, which is the point: the
        // causal link between a decision and the calls it produced was only
        // reconstructable by guesswork before.
        #expect(text.contains("queueCorrelationCleared size=50 diverged transition"))
        #expect(text.contains("deliveryStallDetected playback stalled"))
        #expect(text.contains("queueEndObserved no restart"))

        // The rates table groups them under their own heading once tallied.
        #expect(MusicKitActivityOperation.queueCorrelationCleared.category.title
            == "Overplay playback decisions")
        #expect(MusicKitActivityOperation.deliveryStallDetected.category == .playbackDecision)
        #expect(MusicKitActivityOperation.queueEndObserved.category == .playbackDecision)
        // These must be listed individually, never collapsed into a tally.
        #expect(!MusicKitActivityOperation.queueCorrelationCleared.isHighFrequency)
    }

    @Test("a skipped mode reset is counted apart from one that wrote")
    func skippedModeResetIsCountedApart() {
        let snapshot = MusicKitActivitySnapshot(
            tallies: [],
            events: [
                MusicKitActivityEvent(operation: .playerModeReset, startedAt: start),
                MusicKitActivityEvent(operation: .playerModeResetSkipped, startedAt: start)
            ],
            observationStartedAt: start
        )

        let summary = MusicKitActivityReport.summary(for: snapshot, now: start.addingTimeInterval(60))

        // Otherwise a working guard and a path that never ran look identical.
        #expect(MusicKitActivityOperation.playerModeResetSkipped.title == "Player mode reset (skipped)")
        #expect(MusicKitActivityOperation.playerModeResetSkipped.category == .player)
        #expect(summary.totalCalls >= 0)
    }

    @Test("an event recorded before origins existed still decodes")
    func legacyEventStillDecodes() throws {
        // The activity file persists across relaunch, so older events have no
        // origin field at all.
        let json = Data("""
        {"operation":"playerPlay","startedAt":0,"notes":[]}
        """.utf8)

        let event = try JSONDecoder().decode(MusicKitActivityEvent.self, from: json)
        #expect(event.origin == nil)
        #expect(event.operation == .playerPlay)
    }
}


@Suite("Activity log: origin scoping")
struct MusicKitActivityOriginScopingTests {
    private func makeLog() -> MusicKitActivityLog {
        MusicKitActivityLog(fileURL: nil, persistDelay: .seconds(3600))
    }

    @Test("a command's origin reaches the recorded event")
    func originReachesTheEvent() async {
        let log = makeLog()
        await log.withOrigin(.carPlay) {
            log.record(.playerPlay)
        }

        #expect(log.snapshot().events.last?.origin == .carPlay)
    }

    @Test("origin does not leak past the command that set it")
    func originDoesNotLeakPastTheCommand() async {
        let log = makeLog()
        await log.withOrigin(.remoteCommand) { log.record(.playerPlay) }
        log.record(.artworkDownload)

        let events = log.snapshot().events
        #expect(events.first(where: { $0.operation == .playerPlay })?.origin == .remoteCommand)
        #expect(events.first(where: { $0.operation == .artworkDownload })?.origin == nil)
    }

    @Test("nesting restores the outer origin rather than clearing it")
    func nestingRestoresTheOuterOrigin() async {
        let log = makeLog()
        await log.withOrigin(.carPlay) {
            await log.withOrigin(.automatic) { log.record(.playerSkipNext) }
            log.record(.playerPlay)
        }

        let events = log.snapshot().events
        #expect(events.first(where: { $0.operation == .playerSkipNext })?.origin == .automatic)
        #expect(events.first(where: { $0.operation == .playerPlay })?.origin == .carPlay)
    }

    @Test("a concurrent recorder is not attributed to another task's command")
    func concurrentRecorderIsNotMisattributed() async {
        // The log is written from several isolation domains at once. A shared
        // stack would tag this background call with whatever command happened
        // to be in flight.
        let log = makeLog()
        await log.withOrigin(.carPlay) {
            await Task.detached { log.record(.artworkDownload) }.value
            log.record(.playerPlay)
        }

        let events = log.snapshot().events
        #expect(events.first(where: { $0.operation == .artworkDownload })?.origin == nil)
        #expect(events.first(where: { $0.operation == .playerPlay })?.origin == .carPlay)
    }
}

@Suite("Activity report: latency compares like with like")
struct MusicKitActivityLatencySizeTests {
    private let start = Date(timeIntervalSince1970: 3_000_000)

    private func sized(
        _ offsetMinutes: Double,
        milliseconds: Double,
        size: Double
    ) -> MusicKitActivityEvent {
        MusicKitActivityEvent(
            operation: .playlistTrackFetch,
            startedAt: start.addingTimeInterval(offsetMinutes * 60),
            durationMilliseconds: milliseconds,
            magnitude: size
        )
    }

    @Test("a bigger payload taking proportionally longer is not a slowdown")
    func biggerPayloadIsNotASlowdown() {
        // 25 items at 5ms then 169 items at ~34ms is the same speed per item.
        let events = [
            sized(0, milliseconds: 5, size: 25),
            sized(1, milliseconds: 5, size: 25),
            sized(2, milliseconds: 5, size: 25),
            sized(10, milliseconds: 340, size: 1690),
            sized(11, milliseconds: 340, size: 1690),
            sized(12, milliseconds: 340, size: 1690)
        ]

        #expect(MusicKitActivityReport.latencyConcerns(
            events: events,
            now: start.addingTimeInterval(20 * 60)
        ).isEmpty)
    }

    @Test("the same payload getting slower is still reported")
    func samePayloadGettingSlowerIsReported() {
        let events = [
            sized(0, milliseconds: 8, size: 169),
            sized(1, milliseconds: 7, size: 169),
            sized(2, milliseconds: 9, size: 169),
            sized(10, milliseconds: 4603, size: 169),
            sized(11, milliseconds: 4200, size: 169),
            sized(12, milliseconds: 3900, size: 169)
        ]

        let concerns = MusicKitActivityReport.latencyConcerns(
            events: events,
            now: start.addingTimeInterval(13 * 60)
        )
        #expect(concerns.count == 1)
        #expect(concerns.first?.isActive == true)
    }

    @Test("a degradation that stopped hours ago is reported but not active")
    func staleDegradationIsNotActive() {
        let events = [
            sized(0, milliseconds: 8, size: 169),
            sized(1, milliseconds: 7, size: 169),
            sized(2, milliseconds: 9, size: 169),
            sized(10, milliseconds: 4603, size: 169),
            sized(11, milliseconds: 4200, size: 169),
            sized(12, milliseconds: 3900, size: 169)
        ]

        let concerns = MusicKitActivityReport.latencyConcerns(
            events: events,
            now: start.addingTimeInterval(6 * 60 * 60)
        )
        #expect(concerns.first?.isActive == false)
    }
}
