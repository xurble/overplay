import Foundation
import Synchronization
import Testing
@testable import Overplay

@Suite("MusicKit activity log")
struct MusicKitActivityLogTests {
    // MARK: - Recording

    @Test("a recorded call is tallied into its own minute bucket")
    func aRecordedCallIsTalliedIntoItsOwnMinuteBucket() {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let log = makeLog(clock: clock)

        log.record(.catalogSearch, magnitude: 20)
        log.record(.catalogSearch, magnitude: 5)
        clock.advance(by: 120)
        log.record(.catalogSearch)

        let snapshot = log.snapshot()
        let searchTallies = snapshot.tallies.filter { $0.operation == .catalogSearch }

        #expect(searchTallies.count == 2)
        #expect(searchTallies.first?.count == 2)
        #expect(searchTallies.first?.maximumMagnitude == 20)
        #expect(searchTallies.last?.count == 1)
        #expect(snapshot.observationStartedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("failures are counted separately in the tally")
    func failuresAreCountedSeparatelyInTheTally() {
        let log = makeLog()

        log.record(.playerPlay)
        log.record(.playerPlay, error: error(domain: "MPMusicPlayerControllerErrorDomain", code: 6))

        let tally = log.snapshot().tallies.first { $0.operation == .playerPlay }

        #expect(tally?.count == 2)
        #expect(tally?.failureCount == 1)
    }

    @Test("notable calls are listed individually")
    func notableCallsAreListedIndividually() {
        let log = makeLog()

        log.record(.queueReplace, magnitude: 900)
        log.record(.libraryPlaylistEdit, magnitude: 400)

        let events = log.snapshot().events

        #expect(events.map(\.operation) == [.queueReplace, .libraryPlaylistEdit])
        #expect(events.first?.magnitude == 900)
    }

    @Test("high-frequency calls are tallied but not listed")
    func highFrequencyCallsAreTalliedButNotListed() {
        let log = makeLog()

        for _ in 0..<50 {
            log.record(.nowPlayingInfoWrite)
        }

        let snapshot = log.snapshot()

        #expect(snapshot.events.isEmpty)
        #expect(snapshot.tallies.first { $0.operation == .nowPlayingInfoWrite }?.count == 50)
    }

    @Test("a high-frequency call is still listed when it fails or carries a note")
    func aHighFrequencyCallIsStillListedWhenItFailsOrCarriesANote() {
        let log = makeLog()

        log.record(.artworkDownload)
        log.record(.artworkDownload, error: error(domain: "OverplayArtworkHTTP", code: 429))
        log.record(.nowPlayingInfoWrite, notes: [.automaticRetry])

        let events = log.snapshot().events

        #expect(events.count == 2)
        #expect(events.first?.errorCode == 429)
        #expect(events.last?.notes == [.automaticRetry])
    }

    @Test("the listed call history is capped, keeping the newest calls")
    func theListedCallHistoryIsCappedKeepingTheNewestCalls() {
        let log = makeLog(maximumEvents: 5)

        for index in 0..<20 {
            log.record(.queueReplace, magnitude: Double(index))
        }

        let events = log.snapshot().events

        #expect(events.count == 5)
        #expect(events.compactMap(\.magnitude) == [15, 16, 17, 18, 19].map(Double.init))
    }

    @Test("tallies older than the retention window are pruned")
    func talliesOlderThanTheRetentionWindowArePruned() {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let log = makeLog(retainedMinutes: 10, clock: clock)

        log.record(.catalogSearch)
        clock.advance(by: 11 * 60)
        log.record(.catalogSearch)

        let tallies = log.snapshot().tallies

        #expect(tallies.count == 1)
        #expect(tallies.first?.startDate == clock.now)
    }

    // MARK: - Measuring

    @Test("measuring an async call records its duration and result size")
    func measuringAnAsyncCallRecordsItsDurationAndResultSize() async {
        let log = makeLog()

        let value = await log.measure(
            .libraryTrackQuery,
            resultMagnitude: { Double($0.count) }
        ) {
            await Task.yield()
            return [1, 2, 3]
        }

        #expect(value == [1, 2, 3])
        let event = log.snapshot().events.first
        #expect(event?.operation == .libraryTrackQuery)
        #expect(event?.magnitude == 3)
        #expect(event?.didFail == false)
        #expect((event?.durationMilliseconds ?? -1) >= 0)
    }

    @Test("measuring rethrows and records the failure")
    func measuringRethrowsAndRecordsTheFailure() async {
        let log = makeLog()
        let thrown = error(domain: "TestDomain", code: 429)

        await #expect(throws: NSError.self) {
            try await log.measure(.playlistTrackFetch) {
                await Task.yield()
                throw thrown
            }
        }

        let event = log.snapshot().events.first
        #expect(event?.didFail == true)
        #expect(event?.errorDomain == "TestDomain")
        #expect(event?.errorCode == 429)
    }

    @Test("measuring a synchronous call records it too")
    func measuringASynchronousCallRecordsItToo() {
        let log = makeLog()

        log.measure(.queueReplace, magnitude: 12) { }

        #expect(log.snapshot().events.first?.magnitude == 12)
    }

    // MARK: - Persistence

    @Test("a flushed log is restored by a new instance")
    func aFlushedLogIsRestoredByANewInstance() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let log = MusicKitActivityLog(fileURL: fileURL, now: clock.read)
        log.record(.libraryPlaylistEdit, magnitude: 400, detail: "rewrote playlist")
        log.record(.nowPlayingInfoWrite)
        log.flush()

        let restored = MusicKitActivityLog(fileURL: fileURL, now: clock.read).snapshot()

        #expect(restored.events.count == 1)
        #expect(restored.events.first?.operation == .libraryPlaylistEdit)
        #expect(restored.events.first?.detail == "rewrote playlist")
        #expect(restored.tallies.contains { $0.operation == .nowPlayingInfoWrite && $0.count == 1 })
        #expect(restored.observationStartedAt == clock.now)
    }

    @Test("restoring drops tallies that aged out while the app was gone")
    func restoringDropsTalliesThatAgedOutWhileTheAppWasGone() {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let log = MusicKitActivityLog(fileURL: fileURL, retainedMinutes: 10, now: clock.read)
        log.record(.catalogSearch)
        log.flush()

        clock.advance(by: 60 * 60)
        let restored = MusicKitActivityLog(fileURL: fileURL, retainedMinutes: 10, now: clock.read).snapshot()

        #expect(restored.tallies.isEmpty)
        // The listed call survives so the narrative of the incident is kept.
        #expect(restored.events.count == 1)
    }

    @Test("a missing or unreadable file leaves an empty log")
    func aMissingOrUnreadableFileLeavesAnEmptyLog() throws {
        let fileURL = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)

        let snapshot = MusicKitActivityLog(fileURL: fileURL).snapshot()

        #expect(snapshot.tallies.isEmpty)
        #expect(snapshot.events.isEmpty)
    }

    @Test("resetting clears recorded activity and restarts observation")
    func resettingClearsRecordedActivityAndRestartsObservation() {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let log = makeLog(clock: clock)
        log.record(.queueReplace, magnitude: 10)

        clock.advance(by: 300)
        log.reset()

        let snapshot = log.snapshot()
        #expect(snapshot.events.isEmpty)
        #expect(snapshot.tallies.isEmpty)
        #expect(snapshot.observationStartedAt == clock.now)
    }

    // MARK: - Report

    @Test("the log's report reflects what was recorded")
    func theLogsReportReflectsWhatWasRecorded() {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let log = makeLog(clock: clock)

        log.record(.queueReplace, magnitude: MusicKitActivityReport.largeQueueEntryCount + 100)

        let summary = log.report()

        #expect(summary.totalCalls == 1)
        #expect(summary.concerns.contains { $0.title == "Very large player queue hand-offs" })
    }

    // MARK: - Fixtures

    /// No file URL, so logic tests never touch the shared on-disk snapshot.
    private func makeLog(
        maximumEvents: Int = MusicKitActivityLog.defaultMaximumEvents,
        retainedMinutes: Int = MusicKitActivityLog.defaultRetainedMinutes,
        clock: TestClock = TestClock(start: Date(timeIntervalSince1970: 1_800_000_000))
    ) -> MusicKitActivityLog {
        MusicKitActivityLog(
            fileURL: nil,
            maximumEvents: maximumEvents,
            retainedMinutes: retainedMinutes,
            now: clock.read
        )
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OverplayActivityLogTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("musickit-activity.json")
    }

    private func error(domain: String, code: Int) -> NSError {
        NSError(
            domain: domain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: "Test failure."]
        )
    }
}

/// A settable clock for the log's injected `now`. The log records from any
/// isolation domain, so the closure it takes must be `@Sendable`.
nonisolated final class TestClock: Sendable {
    private let storage: Mutex<Date>

    init(start: Date) {
        storage = Mutex(start)
    }

    var now: Date {
        storage.withLock { $0 }
    }

    var read: @Sendable () -> Date {
        { [self] in self.now }
    }

    func advance(by seconds: TimeInterval) {
        storage.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}
