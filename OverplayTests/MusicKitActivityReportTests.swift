import Foundation
import Testing
@testable import Overplay

@Suite("MusicKit activity report")
struct MusicKitActivityReportTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Rates

    @Test("rate windows count only the tallies inside each window")
    func rateWindowsCountOnlyTheTalliesInsideEachWindow() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let tallies = [
            tally(.catalogSearch, minutesAgo: 0, count: 2, from: currentMinute),
            tally(.catalogSearch, minutesAgo: 3, count: 5, from: currentMinute),
            tally(.catalogSearch, minutesAgo: 30, count: 7, from: currentMinute),
            tally(.catalogSearch, minutesAgo: 90, count: 11, from: currentMinute)
        ]

        let rate = MusicKitActivityReport.operationRates(for: tallies, now: Self.now)
            .first { $0.operation == .catalogSearch }

        #expect(rate?.lastMinute == 2)
        #expect(rate?.lastFiveMinutes == 7)
        #expect(rate?.lastHour == 14)
        #expect(rate?.total == 25)
    }

    @Test("maximum magnitude is the largest seen across all retained minutes")
    func maximumMagnitudeIsTheLargestSeenAcrossAllRetainedMinutes() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let tallies = [
            tally(.queueReplace, minutesAgo: 0, count: 1, from: currentMinute, maximumMagnitude: 40),
            tally(.queueReplace, minutesAgo: 20, count: 1, from: currentMinute, maximumMagnitude: 1_204),
            tally(.queueReplace, minutesAgo: 40, count: 1, from: currentMinute, maximumMagnitude: 90)
        ]

        let rate = MusicKitActivityReport.operationRates(for: tallies, now: Self.now)
            .first { $0.operation == .queueReplace }

        #expect(rate?.maximumMagnitude == 1_204)
        #expect(rate?.total == 3)
    }

    @Test("rates are ordered by the operation declaration order")
    func ratesAreOrderedByTheOperationDeclarationOrder() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let tallies = [
            tally(.nowPlayingInfoWrite, minutesAgo: 0, count: 1, from: currentMinute),
            tally(.catalogSearch, minutesAgo: 0, count: 1, from: currentMinute)
        ]

        let operations = MusicKitActivityReport.operationRates(for: tallies, now: Self.now)
            .map(\.operation)

        #expect(operations == [.catalogSearch, .nowPlayingInfoWrite])
    }

    // MARK: - Failure grouping and classification

    @Test("failures group by operation, domain, and code")
    func failuresGroupByOperationDomainAndCode() {
        let events = [
            failedEvent(.playerPlay, domain: "MPMusicPlayerControllerErrorDomain", code: 6, secondsAgo: 300),
            failedEvent(.playerPlay, domain: "MPMusicPlayerControllerErrorDomain", code: 6, secondsAgo: 120),
            failedEvent(.playerPlay, domain: "MPMusicPlayerControllerErrorDomain", code: 6, secondsAgo: 10),
            failedEvent(.catalogSearch, domain: "NSURLErrorDomain", code: -1009, secondsAgo: 60)
        ]

        let groups = MusicKitActivityReport.failureGroups(for: events)

        #expect(groups.count == 2)
        // Ordered by count, so the repeated player failure comes first.
        #expect(groups.first?.operation == .playerPlay)
        #expect(groups.first?.count == 3)
        #expect(groups.first?.firstAt == Self.now.addingTimeInterval(-300))
        #expect(groups.first?.lastAt == Self.now.addingTimeInterval(-10))
        #expect(groups.last?.classification == .network)
    }

    @Test("successful events never appear as failures")
    func successfulEventsNeverAppearAsFailures() {
        let events = [event(.queueReplace, magnitude: 12, secondsAgo: 5)]

        #expect(MusicKitActivityReport.failureGroups(for: events).isEmpty)
    }

    @Test("failures are classified from status code, domain, and description")
    func failuresAreClassifiedFromStatusCodeDomainAndDescription() {
        struct Case {
            var domain: String?
            var code: Int?
            var description: String?
            var expected: MusicKitActivityReport.FailureClassification
        }

        let cases = [
            Case(domain: nil, code: 429, description: nil, expected: .rateLimited),
            Case(
                domain: nil,
                code: nil,
                description: "Too many requests for this developer token",
                expected: .rateLimited
            ),
            Case(domain: nil, code: 503, description: nil, expected: .serviceUnavailable),
            Case(domain: nil, code: 403, description: nil, expected: .authorization),
            Case(domain: nil, code: nil, description: "The developer token is invalid", expected: .authorization),
            Case(domain: NSURLErrorDomain, code: -1009, description: nil, expected: .network),
            Case(
                domain: "MPMusicPlayerControllerErrorDomain",
                code: 6,
                description: nil,
                expected: .playerRejected
            ),
            Case(domain: "ICErrorDomain", code: 42, description: nil, expected: .mediaServices),
            Case(domain: "SomethingElse", code: 12, description: "unexpected", expected: .other)
        ]

        for testCase in cases {
            let classification = MusicKitActivityReport.classification(
                domain: testCase.domain,
                code: testCase.code,
                description: testCase.description
            )
            #expect(
                classification == testCase.expected,
                "domain=\(testCase.domain ?? "nil") code=\(testCase.code.map(String.init) ?? "nil")"
            )
        }
    }

    @Test("only service refusals count as Apple Music pushing back")
    func onlyServiceRefusalsCountAsAppleMusicPushingBack() {
        #expect(MusicKitActivityReport.FailureClassification.rateLimited.indicatesServiceRefusal)
        #expect(MusicKitActivityReport.FailureClassification.serviceUnavailable.indicatesServiceRefusal)
        #expect(MusicKitActivityReport.FailureClassification.mediaServices.indicatesServiceRefusal)
        #expect(!MusicKitActivityReport.FailureClassification.network.indicatesServiceRefusal)
        #expect(!MusicKitActivityReport.FailureClassification.playerRejected.indicatesServiceRefusal)
        #expect(!MusicKitActivityReport.FailureClassification.other.indicatesServiceRefusal)
    }

    // MARK: - Concerns

    @Test("a quiet snapshot raises no concerns")
    func aQuietSnapshotRaisesNoConcerns() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let snapshot = MusicKitActivitySnapshot(
            tallies: [
                tally(.catalogSearch, minutesAgo: 0, count: 1, from: currentMinute),
                tally(.queueReplace, minutesAgo: 2, count: 1, from: currentMinute, maximumMagnitude: 60),
                tally(.nowPlayingInfoWrite, minutesAgo: 0, count: 3, from: currentMinute)
            ],
            events: [event(.queueReplace, magnitude: 60, secondsAgo: 120)],
            observationStartedAt: Self.now.addingTimeInterval(-3_600)
        )

        let summary = MusicKitActivityReport.summary(for: snapshot, now: Self.now)

        #expect(summary.concerns.isEmpty)
        #expect(summary.totalCalls == 5)
        #expect(!summary.hasCriticalConcern)
    }

    @Test("a rate-limited failure is critical")
    func aRateLimitedFailureIsCritical() {
        let snapshot = MusicKitActivitySnapshot(
            events: [
                failedEvent(.playlistTrackFetch, domain: "MusicDataRequest.Error", code: 429, secondsAgo: 30)
            ]
        )

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(concerns.contains { $0.severity == .critical && $0.title.contains("rate limited") })
    }

    @Test("a very large queue replacement is flagged")
    func aVeryLargeQueueReplacementIsFlagged() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let snapshot = MusicKitActivitySnapshot(
            tallies: [
                tally(
                    .queueReplace,
                    minutesAgo: 1,
                    count: 1,
                    from: currentMinute,
                    maximumMagnitude: MusicKitActivityReport.largeQueueEntryCount
                )
            ]
        )

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(concerns.contains { $0.title == "Very large player queue hand-offs" })
    }

    @Test("repeated queue replacement inside the burst window is flagged")
    func repeatedQueueReplacementInsideTheBurstWindowIsFlagged() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let snapshot = MusicKitActivitySnapshot(
            tallies: [
                tally(
                    .queueReplace,
                    minutesAgo: 1,
                    count: MusicKitActivityReport.queueReplaceBurstCount,
                    from: currentMinute,
                    maximumMagnitude: 20
                )
            ]
        )

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(concerns.contains { $0.title == "Repeated queue replacement" })
    }

    @Test("queue replacements outside the burst window are not flagged")
    func queueReplacementsOutsideTheBurstWindowAreNotFlagged() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let snapshot = MusicKitActivitySnapshot(
            tallies: [
                tally(
                    .queueReplace,
                    minutesAgo: MusicKitActivityReport.queueReplaceBurstWindowMinutes,
                    count: MusicKitActivityReport.queueReplaceBurstCount + 5,
                    from: currentMinute,
                    maximumMagnitude: 20
                )
            ]
        )

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(!concerns.contains { $0.title == "Repeated queue replacement" })
    }

    @Test("rapid Apple Music library writes are flagged across write operations")
    func rapidAppleMusicLibraryWritesAreFlaggedAcrossWriteOperations() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let snapshot = MusicKitActivitySnapshot(
            tallies: [
                tally(.libraryPlaylistEdit, minutesAgo: 0, count: 3, from: currentMinute),
                tally(.libraryPlaylistAddItem, minutesAgo: 2, count: 2, from: currentMinute)
            ]
        )

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(concerns.contains { $0.title == "Rapid Apple Music library writes" })
    }

    @Test("Now Playing churn in the last minute is flagged")
    func nowPlayingChurnInTheLastMinuteIsFlagged() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let snapshot = MusicKitActivitySnapshot(
            tallies: [
                tally(
                    .nowPlayingInfoWrite,
                    minutesAgo: 0,
                    count: MusicKitActivityReport.nowPlayingWritesPerMinuteLimit,
                    from: currentMinute
                )
            ]
        )

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(concerns.contains { $0.title == "Now Playing session churn" })
    }

    @Test("Now Playing writes while not playing are flagged separately")
    func nowPlayingWritesWhileNotPlayingAreFlaggedSeparately() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let snapshot = MusicKitActivitySnapshot(
            tallies: [
                tally(
                    .nowPlayingInfoWriteWhilePaused,
                    minutesAgo: 10,
                    count: MusicKitActivityReport.idleNowPlayingWriteCount - 1,
                    from: currentMinute
                ),
                tally(.nowPlayingInfoClear, minutesAgo: 20, count: 1, from: currentMinute)
            ]
        )

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(concerns.contains { $0.title == "Now Playing written while Overplay is not playing" })
        // These are spread across an hour, so the per-minute rule stays quiet.
        #expect(!concerns.contains { $0.title == "Now Playing session churn" })
    }

    @Test("a repeated identical non-refusal failure is flagged as a retry storm")
    func aRepeatedIdenticalNonRefusalFailureIsFlaggedAsARetryStorm() {
        let snapshot = MusicKitActivitySnapshot(
            events: (0..<MusicKitActivityReport.repeatedFailureCount).map { index in
                failedEvent(
                    .playerSkipNext,
                    domain: "MPMusicPlayerControllerErrorDomain",
                    code: 6,
                    secondsAgo: Double(index) * 5
                )
            }
        )

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(concerns.contains { $0.title == "Repeated identical failure" })
    }

    @Test("a service refusal is not double-reported as a retry storm")
    func aServiceRefusalIsNotDoubleReportedAsARetryStorm() {
        let snapshot = MusicKitActivitySnapshot(
            events: (0..<MusicKitActivityReport.repeatedFailureCount).map { index in
                failedEvent(
                    .playlistTrackFetch,
                    domain: "MusicDataRequest.Error",
                    code: 429,
                    secondsAgo: Double(index) * 5
                )
            }
        )

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(!concerns.contains { $0.title == "Repeated identical failure" })
        #expect(concerns.filter { $0.severity == .critical }.count == 1)
    }

    @Test("an old repeated failure is not flagged as a current retry storm")
    func anOldRepeatedFailureIsNotFlaggedAsACurrentRetryStorm() {
        let secondsOutsideWindow = Double(MusicKitActivityReport.repeatedFailureWindowMinutes) * 60 + 60
        let snapshot = MusicKitActivitySnapshot(
            events: (0..<MusicKitActivityReport.repeatedFailureCount).map { index in
                failedEvent(
                    .playerSkipNext,
                    domain: "MPMusicPlayerControllerErrorDomain",
                    code: 6,
                    secondsAgo: secondsOutsideWindow + Double(index)
                )
            }
        )

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(!concerns.contains { $0.title == "Repeated identical failure" })
    }

    @Test("an automatic recovery loop is flagged")
    func anAutomaticRecoveryLoopIsFlagged() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let snapshot = MusicKitActivitySnapshot(
            tallies: [
                tally(
                    .playbackRecoveryAttempt,
                    minutesAgo: 2,
                    count: MusicKitActivityReport.automaticRetryCount,
                    from: currentMinute
                )
            ]
        )

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(concerns.contains { $0.title == "Automatic playback recovery loop" })
    }

    @Test("a truncated paginated collection is critical")
    func aTruncatedPaginatedCollectionIsCritical() {
        var truncated = event(.playlistTrackFetch, magnitude: 100, secondsAgo: 30)
        truncated.notes = [.truncatedCollection]
        let snapshot = MusicKitActivitySnapshot(events: [truncated])

        let concerns = MusicKitActivityReport.summary(for: snapshot, now: Self.now).concerns

        #expect(
            concerns.contains {
                $0.severity == .critical && $0.title == "Paginated Apple Music collection truncated"
            }
        )
    }

    // MARK: - Text

    @Test("report text lists concerns, grouped rates, and failures")
    func reportTextListsConcernsGroupedRatesAndFailures() {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: Self.now)
        let snapshot = MusicKitActivitySnapshot(
            tallies: [
                tally(
                    .queueReplace,
                    minutesAgo: 0,
                    count: 1,
                    from: currentMinute,
                    maximumMagnitude: 1_204
                )
            ],
            events: [
                failedEvent(.playerPlay, domain: "MPMusicPlayerControllerErrorDomain", code: 6, secondsAgo: 5)
            ],
            observationStartedAt: Self.now.addingTimeInterval(-7_200)
        )

        let text = MusicKitActivityReport.summary(for: snapshot, now: Self.now).text

        #expect(text.contains("MusicKit Activity"))
        #expect(text.contains("[WARNING] Very large player queue hand-offs"))
        #expect(text.contains(MusicKitActivityOperation.Category.player.title))
        #expect(text.contains("Queue replace: 1 / 1 / 1 / 1"))
        #expect(text.contains("max size 1204"))
        #expect(text.contains("MPMusicPlayerControllerErrorDomain 6"))
        #expect(text.contains("2h 0m"))
    }

    @Test("report text says so when nothing is recorded")
    func reportTextSaysSoWhenNothingIsRecorded() {
        let text = MusicKitActivityReport.summary(for: MusicKitActivitySnapshot(), now: Self.now).text

        #expect(text.contains("Total recorded calls: 0"))
        #expect(text.contains("Concerns: none detected."))
        #expect(text.contains("none recorded"))
    }

    // MARK: - Fixtures

    private func tally(
        _ operation: MusicKitActivityOperation,
        minutesAgo: Int,
        count: Int,
        from currentMinute: Int,
        failureCount: Int = 0,
        maximumMagnitude: Double? = nil
    ) -> MusicKitActivityTally {
        MusicKitActivityTally(
            minute: currentMinute - minutesAgo,
            operation: operation,
            count: count,
            failureCount: failureCount,
            maximumMagnitude: maximumMagnitude
        )
    }

    private func event(
        _ operation: MusicKitActivityOperation,
        magnitude: Double? = nil,
        secondsAgo: Double
    ) -> MusicKitActivityEvent {
        MusicKitActivityEvent(
            operation: operation,
            startedAt: Self.now.addingTimeInterval(-secondsAgo),
            durationMilliseconds: 12,
            magnitude: magnitude
        )
    }

    private func failedEvent(
        _ operation: MusicKitActivityOperation,
        domain: String,
        code: Int,
        secondsAgo: Double
    ) -> MusicKitActivityEvent {
        MusicKitActivityEvent(
            operation: operation,
            startedAt: Self.now.addingTimeInterval(-secondsAgo),
            durationMilliseconds: 12,
            errorDomain: domain,
            errorCode: code,
            errorDescription: "The operation could not be completed."
        )
    }
}
