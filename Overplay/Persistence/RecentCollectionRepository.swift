import Foundation
import SwiftData

/// The 10 most recently played albums and artists (`PLAY-019`).
enum RecentCollectionRepository {
    static let limit = 10

    /// Most recent first, one per album or artist. A pure read: copies that
    /// CloudKit delivered from another device are hidden here and removed by
    /// the next `record`.
    static func recents(in context: ModelContext) throws -> [RecentCollectionRecord] {
        distinct(try allByRecency(in: context))
    }

    /// The first `limit` distinct entries of a most-recent-first list, for
    /// views that query the records themselves.
    static func distinct(_ byRecency: [RecentCollectionRecord]) -> [RecentCollectionRecord] {
        var seen: Set<String> = []
        return Array(byRecency.filter { seen.insert($0.groupKey).inserted }.prefix(limit))
    }

    static func recent(id: UUID, in context: ModelContext) throws -> RecentCollectionRecord? {
        var descriptor = FetchDescriptor<RecentCollectionRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Puts the collection first with its current songs. The newest copy of an
    /// album or artist is kept; older copies and anything past the limit go.
    @discardableResult
    static func record(
        _ collection: PlaybackCollection,
        songs: [PlaybackCollectionSong],
        artworkURLTemplate: String?,
        at date: Date = .now,
        in context: ModelContext
    ) throws -> RecentCollectionRecord {
        let key = collection.groupKey
        let existing = try allByRecency(in: context).filter { $0.groupKey == key }
        let record: RecentCollectionRecord
        if let newest = existing.first {
            record = newest
            record.update(collection: collection, songs: songs, artworkURLTemplate: artworkURLTemplate, playedAt: date)
        } else {
            record = RecentCollectionRecord(collection: collection, songs: songs,
                                            artworkURLTemplate: artworkURLTemplate, playedAt: date)
            context.insert(record)
        }
        try prune(in: context)
        try context.save()
        return record
    }

    private static func prune(in context: ModelContext) throws {
        var kept: Set<String> = []
        for record in try allByRecency(in: context) {
            if kept.count < limit, kept.insert(record.groupKey).inserted { continue }
            context.delete(record)
        }
    }

    private static func allByRecency(in context: ModelContext) throws -> [RecentCollectionRecord] {
        var descriptor = FetchDescriptor<RecentCollectionRecord>(sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)])
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }
}
