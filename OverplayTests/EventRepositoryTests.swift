import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
@Suite("Event repository")
struct EventRepositoryTests {
    @Test("recent events are paged newest-first with a has-more marker")
    func recentEventsArePagedNewestFirstWithAHasMoreMarker() throws {
        let context = try makeContext()
        let base = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<5 {
            context.insert(HistoryEvent(
                eventType: .playthrough,
                source: .playback,
                createdAt: base.addingTimeInterval(Double(index))
            ))
        }
        try context.save()

        let firstPage = try EventRepository.recentEvents(matching: .all, limit: 3, in: context)
        #expect(firstPage.events.count == 3)
        #expect(firstPage.hasMore)
        #expect(firstPage.events.map(\.createdAt) == firstPage.events.map(\.createdAt).sorted(by: >))

        let fullPage = try EventRepository.recentEvents(matching: .all, limit: 5, in: context)
        #expect(fullPage.events.count == 5)
        #expect(!fullPage.hasMore)
    }

    @Test("filter predicates match the in-memory filter definitions")
    func filterPredicatesMatchTheInMemoryFilterDefinitions() throws {
        let context = try makeContext()
        let events = [
            HistoryEvent(eventType: .playthrough, source: .reconciled),
            HistoryEvent(eventType: .playthrough, source: .playback),
            HistoryEvent(eventType: .evicted, source: .user),
            HistoryEvent(eventType: .trackRemoved, source: .sync),
            HistoryEvent(eventType: .playlistRemoved, source: .user),
            HistoryEvent(eventType: .promoted, source: .user),
            HistoryEvent(eventType: .restored, source: .user),
            HistoryEvent(eventType: .remoteMutation, source: .overplay),
            HistoryEvent(eventType: .evicted, source: .user, remoteMutationStatus: .pending),
            HistoryEvent(eventType: .skipIgnored, source: .playback)
        ]
        events.forEach(context.insert)
        try context.save()

        for filter in HistoryEventFilter.allCases {
            let fetched = try EventRepository.recentEvents(matching: filter, limit: 100, in: context)
            let expected = events.filter { filter.includes($0) }
            #expect(
                Set(fetched.events.map(\.id)) == Set(expected.map(\.id)),
                "predicate for \(filter.rawValue) diverges from includes(_:)"
            )
        }
    }

    @Test("recovered playthrough events fetch only reconciled playthroughs")
    func recoveredPlaythroughEventsFetchOnlyReconciledPlaythroughs() throws {
        let context = try makeContext()
        context.insert(HistoryEvent(eventType: .playthrough, source: .reconciled))
        context.insert(HistoryEvent(eventType: .playthrough, source: .playback))
        context.insert(HistoryEvent(eventType: .skipCounted, source: .reconciled))
        try context.save()

        let recovered = try EventRepository.recoveredPlaythroughEvents(in: context)
        #expect(recovered.count == 1)
        #expect(recovered.first?.eventType == .playthrough)
        #expect(recovered.first?.source == .reconciled)
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try OverplayTestSupport.makeModelContainer())
    }
}
