import Foundation
import SwiftData

enum EventRepository {
    static let historyPageSize = 100

    struct RecentEventsPage {
        var events: [HistoryEvent]
        var hasMore: Bool
    }

    /// Newest-first page of history events matching the filter. Filtering
    /// happens in the store predicate and the fetch is bounded, so the
    /// History screen never materializes the full, ever-growing event log.
    static func recentEvents(
        matching filter: HistoryEventFilter,
        limit: Int = historyPageSize,
        in context: ModelContext
    ) throws -> RecentEventsPage {
        var descriptor = FetchDescriptor<HistoryEvent>(
            predicate: predicate(for: filter),
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit + 1

        let events = try context.fetch(descriptor)
        return RecentEventsPage(
            events: Array(events.prefix(limit)),
            hasMore: events.count > limit
        )
    }

    /// Reconciled-playthrough events for the recovery summary — a naturally
    /// small subset, fetched by predicate instead of scanning every event.
    static func recoveredPlaythroughEvents(in context: ModelContext) throws -> [HistoryEvent] {
        try context.fetch(FetchDescriptor<HistoryEvent>(
            predicate: predicate(for: .recoveredPlayback),
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))
    }

    static func predicate(for filter: HistoryEventFilter) -> Predicate<HistoryEvent>? {
        switch filter {
        case .all:
            return nil
        case .recoveredPlayback:
            let playthrough = HistoryEventType.playthrough.rawValue
            let reconciled = HistoryEventSource.reconciled.rawValue
            return #Predicate {
                $0.eventTypeRawValue == playthrough && $0.sourceRawValue == reconciled
            }
        case .evictions:
            let evicted = HistoryEventType.evicted.rawValue
            return #Predicate { $0.eventTypeRawValue == evicted }
        case .removals:
            let trackRemoved = HistoryEventType.trackRemoved.rawValue
            let playlistRemoved = HistoryEventType.playlistRemoved.rawValue
            return #Predicate {
                $0.eventTypeRawValue == trackRemoved || $0.eventTypeRawValue == playlistRemoved
            }
        case .promotions:
            let promoted = HistoryEventType.promoted.rawValue
            return #Predicate { $0.eventTypeRawValue == promoted }
        case .restores:
            let restored = HistoryEventType.restored.rawValue
            return #Predicate { $0.eventTypeRawValue == restored }
        case .remoteMutations:
            let remoteMutation = HistoryEventType.remoteMutation.rawValue
            return #Predicate {
                $0.eventTypeRawValue == remoteMutation || $0.remoteMutationStatusRawValue != nil
            }
        }
    }

    @discardableResult
    static func logHistory(
        playlistID: UUID? = nil,
        trackID: UUID? = nil,
        eventType: HistoryEventType,
        source: HistoryEventSource,
        reconciliationMechanism: PlaybackReconciliationMechanism? = nil,
        skipCountAtEvent: Int? = nil,
        positionSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        progressPercentage: Double? = nil,
        remoteMutationStatus: RemoteMutationStatus? = nil,
        message: String? = nil,
        in context: ModelContext
    ) -> HistoryEvent {
        let event = HistoryEvent(
            playlistID: playlistID,
            trackID: trackID,
            eventType: eventType,
            source: source,
            reconciliationMechanism: reconciliationMechanism,
            skipCountAtEvent: skipCountAtEvent,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            progressPercentage: progressPercentage,
            remoteMutationStatus: remoteMutationStatus,
            message: message
        )
        context.insert(event)
        return event
    }
}
