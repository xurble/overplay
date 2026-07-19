import Foundation
import SwiftData

/// Compacts the history log so it cannot grow without bound — every playback
/// transition writes at least one event and the store syncs to CloudKit.
/// skipIgnored events are diagnostic noise (logged on nearly every
/// pause/short-listen transition), so they get a much shorter horizon than
/// user-meaningful history.
@MainActor
enum HistoryRetentionService {
    static let skipIgnoredRetentionDays = 30.0
    static let defaultRetentionDays = 365.0
    /// Per-run deletion cap keeps a large backlog from stalling startup;
    /// the pass runs on every launch, so backlogs drain across sessions.
    static let deletionBatchLimit = 500

    @discardableResult
    static func compact(now: Date = .now, in context: ModelContext) throws -> Int {
        var budget = deletionBatchLimit
        var deletedCount = 0

        let skipIgnored = HistoryEventType.skipIgnored.rawValue
        let skipIgnoredCutoff = cutoff(daysBefore: now, days: skipIgnoredRetentionDays)
        deletedCount += try delete(
            matching: #Predicate {
                $0.eventTypeRawValue == skipIgnored && $0.createdAt < skipIgnoredCutoff
            },
            budget: &budget,
            in: context
        )

        let defaultCutoff = cutoff(daysBefore: now, days: defaultRetentionDays)
        deletedCount += try delete(
            matching: #Predicate { $0.createdAt < defaultCutoff },
            budget: &budget,
            in: context
        )

        if deletedCount > 0 {
            try context.save()
            TrackMetadataDiagnostics.log("history retention removed \(deletedCount) expired events")
        }
        return deletedCount
    }

    private static func cutoff(daysBefore now: Date, days: Double) -> Date {
        now.addingTimeInterval(-days * 24 * 60 * 60)
    }

    private static func delete(
        matching predicate: Predicate<HistoryEvent>,
        budget: inout Int,
        in context: ModelContext
    ) throws -> Int {
        guard budget > 0 else { return 0 }

        var descriptor = FetchDescriptor<HistoryEvent>(predicate: predicate)
        descriptor.fetchLimit = budget
        let events = try context.fetch(descriptor)
        for event in events {
            context.delete(event)
        }
        budget -= events.count
        return events.count
    }
}
