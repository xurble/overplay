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
