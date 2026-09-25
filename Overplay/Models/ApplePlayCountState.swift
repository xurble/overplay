import Foundation

/// A joinable snapshot. Devices publish immutable copies; they never overwrite
/// another device's evidence. `count` is a persisted floor, not a fresh subtraction.
nonisolated struct ApplePlayCountState: Codable, Equatable, Sendable {
    struct Seed: Codable, Equatable, Sendable {
        var id: UUID
        var count: Int
        var musicItemIDs: [String] = []
        var firstObservedAt: Date = .distantFuture
        var baselineID: String = ""
        var identityAliases: [String]? = nil
    }

    struct Counter: Codable, Equatable, Sendable {
        var musicItemID: String
        var baseline: Int
        var latest: Int
        var firstObservedAt: Date
        var baselineID: String
    }

    var seeds: [Seed]
    var counters: [Counter] = []
    var lineageIDs: [UUID]
    var resetAt: Date = .distantPast
    var resetID: String = ""
    private(set) var count: Int

    init(initialCount: Int, originID: UUID, musicItemIDs: [String] = [], identityAliases: [String] = []) {
        seeds = [Seed(id: originID, count: max(0, initialCount), musicItemIDs: musicItemIDs,
                      identityAliases: identityAliases.isEmpty ? nil : identityAliases)]
        lineageIDs = [originID]
        count = max(0, initialCount)
    }

    mutating func observe(musicItemID: String, count: Int, at date: Date, aliases: [String] = []) {
        guard count >= 0 else { return }
        let firstCounter = counters.isEmpty
        if let index = counters.firstIndex(where: { $0.musicItemID == musicItemID }) {
            counters[index].latest = max(counters[index].latest, count)
        } else {
            let baselineID = UUID().uuidString
            counters.append(Counter(musicItemID: musicItemID, baseline: count,
                                    latest: count, firstObservedAt: date,
                                    baselineID: baselineID))
            counters.sort { $0.musicItemID < $1.musicItemID }
        }
        let observedAliases = Set(aliases + [musicItemID])
        for index in seeds.indices where seeds[index].baselineID.isEmpty {
            let seed = seeds[index]
            let matches = seed.musicItemIDs.contains(musicItemID)
                || (seed.musicItemIDs.isEmpty && !observedAliases.isDisjoint(with: seed.identityAliases ?? []))
                || (firstCounter && seeds.count == 1 && seed.musicItemIDs.isEmpty)
            guard matches else { continue }
            seeds[index].musicItemIDs = [musicItemID]
            seeds[index].firstObservedAt = date
            seeds[index].baselineID = counters.first { $0.musicItemID == musicItemID }!.baselineID
        }
        advance()
    }

    mutating func prepareFirstObservation(initialCount: Int, originID: UUID) {
        guard counters.isEmpty, seeds.count == 1, seeds[0].id == originID else { return }
        seeds[0].count = max(seeds[0].count, initialCount)
    }

    /// Explicit track merges and reconciliation calculate once after joining
    /// all evidence. Intermediate join order must not invent an inflated floor.
    mutating func merge(_ other: Self) {
        self = Self.joined([self, other])!
        advance()
    }

    mutating func advance() {
        let calculated = initialCredit + counters.reduce(0) { $0 + max(0, $1.latest - $1.baseline) }
        count = max(count, calculated)
    }

    /// Joining is commutative, associative and idempotent. It preserves the
    /// highest *published* count even when a different baseline wins later.
    static func joined(_ states: [Self]) -> Self? {
        guard let epoch = states.max(by: { ($0.resetAt, $0.resetID) < ($1.resetAt, $1.resetID) }) else { return nil }
        let active = states.filter { $0.resetAt == epoch.resetAt && $0.resetID == epoch.resetID }
        var result = epoch
        result.count = active.map(\.count).max() ?? 0
        result.lineageIDs = Array(Set(states.flatMap(\.lineageIDs))).sorted { $0.uuidString < $1.uuidString }
        var seeds: [UUID: Seed] = [:]
        var counters: [String: Counter] = [:]
        for state in active {
            for seed in state.seeds {
                if let existing = seeds[seed.id] {
                    // Keep the starting credit paired with its first observation.
                    // Combining a later credit with an earlier baseline would
                    // count the intervening plays twice.
                    var canonical = (existing.firstObservedAt, existing.baselineID) < (seed.firstObservedAt, seed.baselineID)
                        ? existing : seed
                    if existing.firstObservedAt == seed.firstObservedAt && existing.baselineID == seed.baselineID {
                        canonical.count = max(existing.count, seed.count)
                    }
                    canonical.musicItemIDs = Array(Set(existing.musicItemIDs + seed.musicItemIDs)).sorted()
                    let aliases = Array(Set((existing.identityAliases ?? []) + (seed.identityAliases ?? []))).sorted()
                    canonical.identityAliases = aliases.isEmpty ? nil : aliases
                    seeds[seed.id] = canonical
                } else { seeds[seed.id] = seed }
            }
            for counter in state.counters {
                if let existing = counters[counter.musicItemID] {
                    var canonical = (existing.firstObservedAt, existing.baselineID) < (counter.firstObservedAt, counter.baselineID)
                        ? existing : counter
                    canonical.latest = max(existing.latest, counter.latest)
                    counters[counter.musicItemID] = canonical
                } else { counters[counter.musicItemID] = counter }
            }
        }
        result.seeds = seeds.values.sorted { $0.id.uuidString < $1.id.uuidString }
        result.counters = counters.values.sorted { $0.musicItemID < $1.musicItemID }
        return result
    }

    private var initialCredit: Int {
        // Credits with a shared library identity are alternative initializations
        // of one counter, not independent plays. Distinct counters retain theirs.
        var groups: [(ids: Set<String>, credit: Int)] = []
        // Unknown identities must not be assumed independent. Their published
        // individual floor is already preserved by the join; defer addition
        // until evidence binds them to a concrete counter.
        for seed in seeds where !seed.musicItemIDs.isEmpty {
            var group = (ids: Set(seed.musicItemIDs), credit: seed.count)
            for index in groups.indices.reversed() where !groups[index].ids.isDisjoint(with: group.ids) {
                group.ids.formUnion(groups[index].ids)
                group.credit = max(group.credit, groups[index].credit)
                groups.remove(at: index)
            }
            groups.append(group)
        }
        return groups.reduce(0) { $0 + $1.credit }
    }

    mutating func reset(at date: Date, id: String) {
        resetAt = date
        resetID = id
        count = 0
        for index in seeds.indices { seeds[index].count = 0 }
        for index in counters.indices {
            counters[index].baseline = counters[index].latest
            counters[index].firstObservedAt = date
            counters[index].baselineID = id
        }
    }
}
