import Foundation
import SwiftData

@MainActor
enum ApplePlayCountRepository {
    private static let deviceID: String = {
        let key = "overplay.applePlayCountDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    static func append(_ state: ApplePlayCountState, for itemID: UUID, in context: ModelContext) {
        context.insert(ApplePlayCountRecord(itemID: itemID, state: state, deviceID: deviceID))
    }

    static func link(donorID: UUID, keeperID: UUID, in context: ModelContext) {
        guard donorID != keeperID else { return }
        // Keep an edge even when neither item has usable Apple metadata yet.
        context.insert(ApplePlayCountRecord(itemID: keeperID, mergedItemID: donorID, deviceID: deviceID))
    }

    /// The display reads only published floors. A baseline arriving later can
    /// never reduce a number that has already been shown. Explicit reset epochs
    /// are the sole exception, and old-epoch deliveries cannot undo a reset.
    static func count(for itemID: UUID, in context: ModelContext) throws -> Int? {
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
