import Foundation

/// Turns recorded Apple Music activity into rates, grouped failures, and a
/// list of call patterns known to overload the shared Apple Music services.
///
/// Pure functions over a snapshot so the rules stay unit-testable without
/// MusicKit, which never behaves meaningfully in the simulator.
nonisolated enum MusicKitActivityReport {
    // MARK: - Thresholds

    /// Queue entries handed to `ApplicationMusicPlayer` in one replacement
    /// before the hand-off counts as very large. Every entry crosses to the
    /// Music app's playback engine on each replacement.
    static let largeQueueEntryCount: Double = 300
    static let queueReplaceBurstWindowMinutes = 5
    static let queueReplaceBurstCount = 5
    static let libraryWriteBurstWindowMinutes = 5
    static let libraryWriteBurstCount = 5
    static let repeatedFailureWindowMinutes = 10
    static let repeatedFailureCount = 3
    /// Now Playing writes per minute above which Overplay is churning the
    /// system Now Playing session rather than reporting state changes.
    static let nowPlayingWritesPerMinuteLimit = 20
    static let idleNowPlayingWriteWindowMinutes = 60
    static let idleNowPlayingWriteCount = 60
    static let automaticRetryWindowMinutes = 10
    static let automaticRetryCount = 4

    // MARK: - Types

    struct OperationRate: Equatable, Sendable {
        var operation: MusicKitActivityOperation
        var lastMinute: Int
        var lastFiveMinutes: Int
        var lastHour: Int
        var total: Int
        var failures: Int
        var maximumMagnitude: Double?
    }

    enum FailureClassification: String, Equatable, Sendable {
        case rateLimited
        case serviceUnavailable
        case authorization
        case network
        case playerRejected
        case mediaServices
        case other

        var title: String {
            switch self {
            case .rateLimited: "rate limited"
            case .serviceUnavailable: "service unavailable"
            case .authorization: "authorization"
            case .network: "network"
            case .playerRejected: "player rejected"
            case .mediaServices: "media services"
            case .other: "other"
            }
        }

        /// Classifications that mean the shared Apple Music services pushed
        /// back on Overplay, rather than a local or connectivity problem.
        var indicatesServiceRefusal: Bool {
            switch self {
            case .rateLimited, .serviceUnavailable, .mediaServices:
                true
            case .authorization, .network, .playerRejected, .other:
                false
            }
        }
    }

    struct FailureGroup: Equatable, Sendable {
        var operation: MusicKitActivityOperation
        var domain: String
        var code: Int
        var classification: FailureClassification
        var count: Int
        var firstAt: Date
        var lastAt: Date
        var errorDescription: String?
    }

    struct Concern: Equatable, Sendable {
        enum Severity: String, Equatable, Sendable {
            case critical
            case warning

            var label: String {
                switch self {
                case .critical: "CRITICAL"
                case .warning: "WARNING"
                }
            }
        }

        var severity: Severity
        var title: String
        var detail: String
    }

    struct Summary: Equatable, Sendable {
        var generatedAt: Date
        var observationStartedAt: Date?
        var totalCalls: Int
        var rates: [OperationRate]
        var failures: [FailureGroup]
        var concerns: [Concern]
        var recentEvents: [MusicKitActivityEvent]
    }

    // MARK: - Summary

    static func summary(for snapshot: MusicKitActivitySnapshot, now: Date) -> Summary {
        let rates = operationRates(for: snapshot.tallies, now: now)
        let failures = failureGroups(for: snapshot.events)
        return Summary(
            generatedAt: now,
            observationStartedAt: snapshot.observationStartedAt,
            totalCalls: rates.reduce(0) { $0 + $1.total },
            rates: rates,
            failures: failures,
            concerns: concerns(
                tallies: snapshot.tallies,
                events: snapshot.events,
                rates: rates,
                failures: failures,
                now: now
            ),
            recentEvents: snapshot.events
        )
    }

    static func operationRates(
        for tallies: [MusicKitActivityTally],
        now: Date
    ) -> [OperationRate] {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: now)
        var rates: [MusicKitActivityOperation: OperationRate] = [:]

        for tally in tallies {
            let age = currentMinute - tally.minute
            var rate = rates[tally.operation] ?? OperationRate(
                operation: tally.operation,
                lastMinute: 0,
                lastFiveMinutes: 0,
                lastHour: 0,
                total: 0,
                failures: 0,
                maximumMagnitude: nil
            )
            if age < 1 { rate.lastMinute += tally.count }
            if age < 5 { rate.lastFiveMinutes += tally.count }
            if age < 60 { rate.lastHour += tally.count }
            rate.total += tally.count
            rate.failures += tally.failureCount
            if let magnitude = tally.maximumMagnitude {
                rate.maximumMagnitude = max(rate.maximumMagnitude ?? magnitude, magnitude)
            }
            rates[tally.operation] = rate
        }

        return MusicKitActivityOperation.allCases.compactMap { rates[$0] }
    }

    static func count(
        of operations: Set<MusicKitActivityOperation>,
        in tallies: [MusicKitActivityTally],
        withinLastMinutes minutes: Int,
        now: Date
    ) -> Int {
        let currentMinute = MusicKitActivityTally.minuteIndex(for: now)
        return tallies
            .filter { operations.contains($0.operation) && currentMinute - $0.minute < minutes }
            .reduce(0) { $0 + $1.count }
    }

    static func failureGroups(for events: [MusicKitActivityEvent]) -> [FailureGroup] {
        var groups: [String: FailureGroup] = [:]

        for event in events where event.didFail {
            let domain = event.errorDomain ?? "unknown"
            let code = event.errorCode ?? 0
            let key = "\(event.operation.rawValue)|\(domain)|\(code)"
            if var group = groups[key] {
                group.count += 1
                group.firstAt = min(group.firstAt, event.startedAt)
                group.lastAt = max(group.lastAt, event.startedAt)
                groups[key] = group
            } else {
                groups[key] = FailureGroup(
                    operation: event.operation,
                    domain: domain,
                    code: code,
                    classification: classification(
                        domain: event.errorDomain,
                        code: event.errorCode,
                        description: event.errorDescription
                    ),
                    count: 1,
                    firstAt: event.startedAt,
                    lastAt: event.startedAt,
                    errorDescription: event.errorDescription
                )
            }
        }

        return groups.values.sorted { left, right in
            left.count == right.count ? left.lastAt > right.lastAt : left.count > right.count
        }
    }

    static func classification(
        domain: String?,
        code: Int?,
        description: String?
    ) -> FailureClassification {
        let domain = domain ?? ""
        let description = description ?? ""

        func mentions(_ needles: [String]) -> Bool {
            needles.contains { description.localizedCaseInsensitiveContains($0) }
        }

        if code == 429 || mentions(["too many requests", "rate limit", "throttl", "exceeded the request"]) {
            return .rateLimited
        }
        if code == 503 || code == 500 || code == 502
            || mentions(["service unavailable", "temporarily unavailable", "internal server error"]) {
            return .serviceUnavailable
        }
        if code == 401 || code == 403
            || mentions(["developer token", "unauthorized", "forbidden", "not authorized"])
            || domain.localizedCaseInsensitiveContains("MusicAuthorization") {
            return .authorization
        }
        if domain == NSURLErrorDomain || mentions(["internet connection", "network connection"]) {
            return .network
        }
        if domain.localizedCaseInsensitiveContains("MPMusicPlayerController")
            || domain.localizedCaseInsensitiveContains("MPError") {
            return .playerRejected
        }
        if domain.localizedCaseInsensitiveContains("ICError")
            || domain.localizedCaseInsensitiveContains("AMSError")
            || domain.localizedCaseInsensitiveContains("MPMediaLibrary")
            || domain.localizedCaseInsensitiveContains("MediaPlayer")
            || domain.localizedCaseInsensitiveContains("MediaLibrary") {
            return .mediaServices
        }
        return .other
    }

    // MARK: - Concerns

    static func concerns(
        tallies: [MusicKitActivityTally],
        events: [MusicKitActivityEvent],
        rates: [OperationRate],
        failures: [FailureGroup],
        now: Date
    ) -> [Concern] {
        var concerns: [Concern] = []
        let ratesByOperation = rates.reduce(into: [MusicKitActivityOperation: OperationRate]()) {
            $0[$1.operation] = $1
        }

        for failure in failures where failure.classification.indicatesServiceRefusal {
            concerns.append(Concern(
                severity: .critical,
                title: "Apple Music refused requests (\(failure.classification.title))",
                detail: """
                \(failure.operation.title) failed \(failure.count)x with \
                \(failure.domain) \(failure.code). Last at \(timeText(failure.lastAt)). \
                \(failure.errorDescription ?? "No description.") \
                A refusal from the shared Apple Music services is the strongest available \
                signal that Overplay's call pattern is being pushed back on.
                """
            ))
        }

        let nowPlayingWrites: Set<MusicKitActivityOperation> = [
            .nowPlayingInfoWrite, .nowPlayingInfoWriteWhilePaused, .nowPlayingInfoClear
        ]
        let nowPlayingLastMinute = nowPlayingWrites.reduce(0) {
            $0 + (ratesByOperation[$1]?.lastMinute ?? 0)
        }
        if nowPlayingLastMinute >= nowPlayingWritesPerMinuteLimit {
            concerns.append(Concern(
                severity: .warning,
                title: "Now Playing session churn",
                detail: """
                \(nowPlayingWrites.reduce(0) { $0 + (ratesByOperation[$1]?.lastMinute ?? 0) }) \
                MPNowPlayingInfoCenter writes in the last minute. Overplay drives playback \
                through ApplicationMusicPlayer, so the Music app already publishes Now Playing \
                for the same audio; a second origin rewriting it every tick is the pattern most \
                likely to confuse the system Now Playing session.
                """
            ))
        }

        let idleNowPlayingWrites = count(
            of: [.nowPlayingInfoWriteWhilePaused, .nowPlayingInfoClear],
            in: tallies,
            withinLastMinutes: idleNowPlayingWriteWindowMinutes,
            now: now
        )
        if idleNowPlayingWrites >= idleNowPlayingWriteCount {
            concerns.append(Concern(
                severity: .warning,
                title: "Now Playing written while Overplay is not playing",
                detail: """
                \(idleNowPlayingWrites) Now Playing writes or clears in the last \
                \(idleNowPlayingWriteWindowMinutes) minutes happened while Overplay was not \
                playing. Publishing or clearing Now Playing when Overplay owns no audio \
                competes with whatever is actually playing, including the Music app itself.
                """
            ))
        }

        if let queueRate = ratesByOperation[.queueReplace] {
            if let maximum = queueRate.maximumMagnitude, maximum >= largeQueueEntryCount {
                concerns.append(Concern(
                    severity: .warning,
                    title: "Very large player queue hand-offs",
                    detail: """
                    Largest queue replacement was \(Int(maximum)) entries. The whole queue \
                    crosses to the Music app's playback engine on every replacement, and \
                    Overplay replaces the full playlist rather than a window of it.
                    """
                ))
            }

            let burst = count(
                of: [.queueReplace],
                in: tallies,
                withinLastMinutes: queueReplaceBurstWindowMinutes,
                now: now
            )
            if burst >= queueReplaceBurstCount {
                concerns.append(Concern(
                    severity: .warning,
                    title: "Repeated queue replacement",
                    detail: """
                    \(burst) queue replacements in the last \(queueReplaceBurstWindowMinutes) \
                    minutes. Each one tears down and rebuilds the Music app's queue.
                    """
                ))
            }
        }

        let libraryWrites = Set(MusicKitActivityOperation.allCases.filter(\.mutatesAppleMusicLibrary))
        let libraryWriteBurst = count(
            of: libraryWrites,
            in: tallies,
            withinLastMinutes: libraryWriteBurstWindowMinutes,
            now: now
        )
        if libraryWriteBurst >= libraryWriteBurstCount {
            concerns.append(Concern(
                severity: .warning,
                title: "Rapid Apple Music library writes",
                detail: """
                \(libraryWriteBurst) library mutations in the last \
                \(libraryWriteBurstWindowMinutes) minutes. Each one syncs through iCloud Music \
                Library, and a playlist rewrite resends every remaining track.
                """
            ))
        }

        for failure in failures
        where failure.count >= repeatedFailureCount
            && failure.lastAt >= now.addingTimeInterval(-Double(repeatedFailureWindowMinutes) * 60)
            && !failure.classification.indicatesServiceRefusal {
            concerns.append(Concern(
                severity: .warning,
                title: "Repeated identical failure",
                detail: """
                \(failure.operation.title) failed \(failure.count)x with \(failure.domain) \
                \(failure.code) (\(failure.classification.title)), last at \
                \(timeText(failure.lastAt)). Repeating a call that keeps failing the same way \
                is the shape of a retry storm.
                """
            ))
        }

        let automaticRetries = count(
            of: [.playbackRecoveryAttempt],
            in: tallies,
            withinLastMinutes: automaticRetryWindowMinutes,
            now: now
        )
        if automaticRetries >= automaticRetryCount {
            concerns.append(Concern(
                severity: .warning,
                title: "Automatic playback recovery loop",
                detail: """
                \(automaticRetries) automatic delivery-recovery attempts in the last \
                \(automaticRetryWindowMinutes) minutes. The per-episode budget resets on any \
                single tick of forward progress, so a player that stutters can be re-prodded \
                indefinitely.
                """
            ))
        }

        let truncatedFetches = events.filter { $0.notes.contains(.truncatedCollection) }
        if let latest = truncatedFetches.last {
            concerns.append(Concern(
                severity: .critical,
                title: "Paginated Apple Music collection truncated",
                detail: """
                \(truncatedFetches.count) fetch(es) returned a collection that reported further \
                batches Overplay did not request; the most recent was \(latest.operation.title) \
                at \(timeText(latest.startedAt)) with \(latest.magnitude.map { String(Int($0)) } ?? "?") \
                items. Overplay treats a truncated fetch as the complete remote track list, so \
                sync sees phantom removals and a playlist rewrite can drop the tracks it never saw.
                """
            ))
        }

        return concerns
    }

    // MARK: - Text

    static func text(for summary: Summary) -> String {
        var lines: [String] = []

        lines.append("MusicKit Activity")
        if let observationStartedAt = summary.observationStartedAt {
            let elapsed = summary.generatedAt.timeIntervalSince(observationStartedAt)
            lines.append("Observed since \(timeText(observationStartedAt)) (\(durationText(elapsed)))")
        }
        lines.append("Total recorded calls: \(summary.totalCalls)")

        if summary.concerns.isEmpty {
            lines.append("")
            lines.append("Concerns: none detected.")
        } else {
            lines.append("")
            lines.append("Concerns:")
            for concern in summary.concerns {
                lines.append("  [\(concern.severity.label)] \(concern.title)")
                lines.append("    \(collapseWhitespace(concern.detail))")
            }
        }

        lines.append("")
        lines.append("Calls (1m / 5m / 60m / total, failures):")
        if summary.rates.isEmpty {
            lines.append("  none recorded")
        } else {
            for category in MusicKitActivityOperation.Category.allCases {
                let categoryRates = summary.rates.filter { $0.operation.category == category }
                guard !categoryRates.isEmpty else { continue }
                lines.append("  \(category.title)")
                for rate in categoryRates {
                    var line = "    \(rate.operation.title): "
                        + "\(rate.lastMinute) / \(rate.lastFiveMinutes) / \(rate.lastHour) / \(rate.total)"
                    if rate.failures > 0 {
                        line += ", \(rate.failures) failed"
                    }
                    if let maximum = rate.maximumMagnitude {
                        line += ", max size \(Int(maximum))"
                    }
                    lines.append(line)
                }
            }
        }

        lines.append("")
        lines.append("Failures:")
        if summary.failures.isEmpty {
            lines.append("  none recorded")
        } else {
            for failure in summary.failures {
                lines.append(
                    "  \(failure.operation.title) x\(failure.count) "
                        + "[\(failure.classification.title)] \(failure.domain) \(failure.code) "
                        + "last \(timeText(failure.lastAt))"
                )
                if let errorDescription = failure.errorDescription {
                    lines.append("    \(collapseWhitespace(errorDescription))")
                }
            }
        }

        lines.append("")
        lines.append("Recent notable calls (newest last):")
        if summary.recentEvents.isEmpty {
            lines.append("  none recorded")
        } else {
            for event in summary.recentEvents.suffix(60) {
                var line = "  \(timeText(event.startedAt)) \(event.operation.rawValue)"
                if let magnitude = event.magnitude {
                    line += " size=\(Int(magnitude))"
                }
                if let durationMilliseconds = event.durationMilliseconds {
                    line += String(format: " %.0fms", durationMilliseconds)
                }
                if !event.notes.isEmpty {
                    line += " notes=\(event.notes.map(\.rawValue).joined(separator: ","))"
                }
                if let detail = event.detail {
                    line += " \(detail)"
                }
                if event.didFail {
                    line += " FAILED \(event.errorDomain ?? "?") \(event.errorCode ?? 0)"
                    if let errorDescription = event.errorDescription {
                        line += ": \(collapseWhitespace(errorDescription))"
                    }
                }
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

extension MusicKitActivityReport.Summary {
    var text: String {
        MusicKitActivityReport.text(for: self)
    }

    var hasCriticalConcern: Bool {
        concerns.contains { $0.severity == .critical }
    }
}
