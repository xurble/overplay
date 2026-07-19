import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("History retention service")
struct HistoryRetentionServiceTests {
    @Test("expired events are removed and recent events survive")
    func expiredEventsAreRemovedAndRecentEventsSurvive() throws {
        let context = try makeContext()
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        insertEvent(.playthrough, daysAgo: 400, now: now, in: context)
        insertEvent(.playthrough, daysAgo: 300, now: now, in: context)
        insertEvent(.evicted, daysAgo: 10, now: now, in: context)
        try context.save()

        let deleted = try HistoryRetentionService.compact(now: now, in: context)

        #expect(deleted == 1)
        let remaining = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(remaining.count == 2)
        #expect(!remaining.contains { $0.createdAt < now.addingTimeInterval(-365 * 24 * 60 * 60) })
    }

    @Test("skipIgnored noise expires on the shorter horizon")
    func skipIgnoredNoiseExpiresOnTheShorterHorizon() throws {
        let context = try makeContext()
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        insertEvent(.skipIgnored, daysAgo: 45, now: now, in: context)
        insertEvent(.skipIgnored, daysAgo: 5, now: now, in: context)
        // Same age as the expired skipIgnored but a meaningful type: kept.
        insertEvent(.skipCounted, daysAgo: 45, now: now, in: context)
        try context.save()

        let deleted = try HistoryRetentionService.compact(now: now, in: context)

        #expect(deleted == 1)
        let remaining = try context.fetch(FetchDescriptor<HistoryEvent>())
        #expect(remaining.count == 2)
        #expect(remaining.contains { $0.eventType == .skipCounted })
        #expect(remaining.contains { $0.eventType == .skipIgnored })
    }

    @Test("deletions are capped per run so a backlog drains incrementally")
    func deletionsAreCappedPerRunSoABacklogDrainsIncrementally() throws {
        let context = try makeContext()
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        for _ in 0..<(HistoryRetentionService.deletionBatchLimit + 25) {
            insertEvent(.skipIgnored, daysAgo: 60, now: now, in: context)
        }
        try context.save()

        let firstPass = try HistoryRetentionService.compact(now: now, in: context)
        #expect(firstPass == HistoryRetentionService.deletionBatchLimit)

        let secondPass = try HistoryRetentionService.compact(now: now, in: context)
        #expect(secondPass == 25)
        #expect(try context.fetch(FetchDescriptor<HistoryEvent>()).isEmpty)
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try OverplayTestSupport.makeModelContainer())
    }

    private func insertEvent(
        _ eventType: HistoryEventType,
        daysAgo: Double,
        now: Date,
        in context: ModelContext
    ) {
        context.insert(HistoryEvent(
            eventType: eventType,
            source: .playback,
            createdAt: now.addingTimeInterval(-daysAgo * 24 * 60 * 60)
        ))
    }
}
