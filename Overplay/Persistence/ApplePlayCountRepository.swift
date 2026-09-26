import Foundation
import SwiftData

@MainActor
enum ApplePlayCountRepository {
    /// Scoped to a synchronous operation: imports, resets and other contexts can
    /// never leave a long-lived projection stale. Nested callers share the batch.
    private static var projections: [ObjectIdentifier: Projection] = [:]

    static func withSnapshot<T>(for items: [PlaylistItemRecord], in context: ModelContext?, _ body: () throws -> T) rethrows -> T {
        guard let context else { return try body() }
        let key = ObjectIdentifier(context)
        let previous = projections[key]
        let requested = Set(items.map(\.id))
        if let previous, requested.isSubset(of: previous.coveredIDs) { return try body() }
        projections[key] = try? Projection(itemIDs: requested, context: context)
        defer { projections[key] = nil }
        return try body()
    }

    private final class Projection {
        struct Evidence {
            var state: ApplePlayCountState?
            var lineage: [UUID]
            var resetAt: Date
            var resetID: String
            var count: Int
            var hasState: Bool
        }
        var coveredIDs = Set<UUID>()
        var records: [UUID: [Evidence]] = [:]
        var states: [UUID: ApplePlayCountState] = [:]
        var resolved = Set<UUID>()

        init(itemIDs: Set<UUID>, context: ModelContext) throws {
            let span = PerformanceSpan(.playCountEvidenceRead)
            var readCount = 0
            defer { span.finish(magnitude: Double(readCount), detail: "batch") }
            var pending = itemIDs
            var visited = Set<UUID>()
            while !pending.isEmpty {
                let ids = Array(pending)
                visited.formUnion(pending)
                coveredIDs.formUnion(pending)
                let rows = try context.fetch(FetchDescriptor<ApplePlayCountRecord>(predicate: #Predicate { ids.contains($0.itemID) }))
                readCount += rows.count
                for row in rows {
                    records[row.itemID, default: []].append(Evidence(state: row.state, lineage: row.lineageIDs,
                        resetAt: row.resetAt, resetID: row.resetID, count: row.creditedCount, hasState: row.hasState))
                }
                pending = Set(rows.flatMap(\.lineageIDs)).subtracting(visited)
            }
        }

        func state(for id: UUID) -> ApplePlayCountState? {
            if resolved.contains(id) { return states[id] }
            var pending = Set([id])
            var visited = Set<UUID>()
            var values: [ApplePlayCountState] = []
            while let next = pending.popFirst() {
                guard visited.insert(next).inserted else { continue }
                let evidence = records[next] ?? []
                values += evidence.compactMap(\.state)
                pending.formUnion(evidence.flatMap(\.lineage))
            }
            let state = ApplePlayCountState.joined(values)
            resolved.insert(id)
            states[id] = state
            return state
        }

        func count(for id: UUID) -> Int? {
            let own = (records[id] ?? []).filter(\.hasState)
            guard let newest = own.max(by: { ($0.resetAt, $0.resetID) < ($1.resetAt, $1.resetID) }) else { return nil }
            return own.filter { $0.resetAt == newest.resetAt && $0.resetID == newest.resetID && $0.state?.counters.isEmpty == false }
                .map(\.count).max()
        }

        func append(_ record: ApplePlayCountRecord) {
            coveredIDs.insert(record.itemID)
            records[record.itemID, default: []].append(Evidence(state: record.state, lineage: record.lineageIDs,
                resetAt: record.resetAt, resetID: record.resetID, count: record.creditedCount, hasState: record.hasState))
            states.removeAll()
            resolved.removeAll()
        }
    }
    private static let deviceID: String = {
        let key = "overplay.applePlayCountDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    static func append(_ state: ApplePlayCountState, for itemID: UUID, in context: ModelContext) {
        let record = ApplePlayCountRecord(itemID: itemID, state: state, deviceID: deviceID)
        context.insert(record)
        projections[ObjectIdentifier(context)]?.append(record)
    }

    static func link(donorID: UUID, keeperID: UUID, in context: ModelContext) {
        guard donorID != keeperID else { return }
        // Keep an edge even when neither item has usable Apple metadata yet.
        let record = ApplePlayCountRecord(itemID: keeperID, mergedItemID: donorID, deviceID: deviceID)
        context.insert(record)
        projections[ObjectIdentifier(context)] = nil
    }

    /// The display reads only published floors. A baseline arriving later can
    /// never reduce a number that has already been shown. Explicit reset epochs
    /// are the sole exception, and old-epoch deliveries cannot undo a reset.
    static func count(for itemID: UUID, in context: ModelContext) throws -> Int? {
        if let projection = projections[ObjectIdentifier(context)], projection.coveredIDs.contains(itemID) { return projection.count(for: itemID) }
        let span = PerformanceSpan(.playCountEvidenceRead)
        defer { span.finish(detail: "single count") }
        var request = FetchDescriptor<ApplePlayCountRecord>(
            predicate: #Predicate { $0.itemID == itemID && $0.hasState },
            sortBy: [SortDescriptor(\.resetAt, order: .reverse),
                     SortDescriptor(\.resetID, order: .reverse),
                     SortDescriptor(\.creditedCount, order: .reverse)]
        )
        request.fetchLimit = 1
        guard let newest = try context.fetch(request).first else { return nil }
        if newest.state?.counters.isEmpty == false { return newest.creditedCount }
        // A reset-only record must mask older epochs without pretending that
        // zero was observed. Within the epoch, a real zero beats an unresolved
        // reset even when their published floors tie.
        let resetAt = newest.resetAt
        let resetID = newest.resetID
        let epoch = FetchDescriptor<ApplePlayCountRecord>(
            predicate: #Predicate { $0.itemID == itemID && $0.hasState && $0.resetAt == resetAt && $0.resetID == resetID },
            sortBy: [SortDescriptor(\.creditedCount, order: .reverse)]
        )
        return try context.fetch(epoch).first { $0.state?.counters.isEmpty == false }?.creditedCount
    }

    static func state(for itemID: UUID, in context: ModelContext) throws -> ApplePlayCountState? {
        if let projection = projections[ObjectIdentifier(context)], projection.coveredIDs.contains(itemID) { return projection.state(for: itemID) }
        let span = PerformanceSpan(.playCountEvidenceRead)
        defer { span.finish(detail: "single state") }
        var pending = Set([itemID])
        var visited = Set<UUID>()
        var states: [ApplePlayCountState] = []
        // Merge snapshots carry the donor lineage. This also finds observations
        // delivered after a donor item was deleted, without rewriting history.
        while !pending.isEmpty {
            let ids = Array(pending)
            visited.formUnion(pending)
            let request = FetchDescriptor<ApplePlayCountRecord>(predicate: #Predicate { ids.contains($0.itemID) })
            let fetched = try context.fetch(request)
            states.append(contentsOf: fetched.compactMap(\.state))
            pending = Set(fetched.flatMap(\.lineageIDs)).subtracting(visited)
        }
        return ApplePlayCountState.joined(states)
    }
}
