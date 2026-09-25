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
        /// A first observation after an unobserved merge seeds the combined
        /// Overplay total once, including these earlier origin credits.
        var coveredOriginIDs: [UUID]? = nil
    }

    struct Counter: Codable, Equatable, Sendable {
        var musicItemID: String
        var baseline: Int
        var latest: Int
        var firstObservedAt: Date
        var baselineID: String
        var aliases: [String]? = nil
        var isPlaylistCount: Bool? = nil
        var isRecentlyPlayedCount: Bool? = nil

        var isAlternativeCount: Bool { isPlaylistCount == true || isRecentlyPlayedCount == true }
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

    mutating func observe(musicItemID: String, count: Int, at date: Date, aliases: [String] = [],
                          isPlaylistCount: Bool = false, isRecentlyPlayedCount: Bool = false) {
        guard count >= 0 else { return }
        let firstCounter = counters.isEmpty
        if let index = counters.firstIndex(where: { $0.musicItemID == musicItemID }) {
            counters[index].latest = max(counters[index].latest, count)
            let combined = Array(Set((counters[index].aliases ?? []) + aliases)).sorted()
            counters[index].aliases = combined.isEmpty ? nil : combined
        } else {
            let baselineID = UUID().uuidString
            counters.append(Counter(musicItemID: musicItemID, baseline: count,
                                    latest: count, firstObservedAt: date,
                                    baselineID: baselineID, aliases: aliases.isEmpty ? nil : aliases.sorted(),
                                    isPlaylistCount: isPlaylistCount ? true : nil,
                                    isRecentlyPlayedCount: isRecentlyPlayedCount ? true : nil))
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

    mutating func prepareFirstObservation(initialCount: Int, originID: UUID, musicItemID: String) {
        guard counters.isEmpty else { return }
        let origins = Set(seeds.flatMap { [$0.id] + ($0.coveredOriginIDs ?? []) })
        let seed = Seed(id: originID, count: max(count, initialCount), musicItemIDs: [musicItemID],
                        coveredOriginIDs: origins.sorted { $0.uuidString < $1.uuidString })
        seeds.removeAll { $0.id == originID }
        seeds.append(seed)
        seeds.sort { $0.id.uuidString < $1.id.uuidString }
    }

    mutating func retainUnobservedIdentity(originID: UUID, musicItemIDs: [String], aliases: [String]) {
        guard let index = seeds.firstIndex(where: { $0.id == originID }), seeds[index].baselineID.isEmpty else { return }
        if seeds[index].musicItemIDs.isEmpty { seeds[index].musicItemIDs = musicItemIDs }
        let allAliases = Array(Set((seeds[index].identityAliases ?? []) + aliases)).sorted()
        seeds[index].identityAliases = allAliases.isEmpty ? nil : allAliases
    }

    /// Explicit track merges and reconciliation calculate once after joining
    /// all evidence. Intermediate join order must not invent an inflated floor.
    mutating func merge(_ other: Self) {
        self = Self.joined([self, other])!
        advance()
    }

    mutating func advance() {
        // Playlist, recent-history and library views can describe the same listening history.
        // Compare their increases instead of adding them. Each source retains
        // its own baseline because Apple's raw totals need not agree.
        let increase = counterGroups.reduce(0) { total, group in
            let library = group.filter { !$0.isAlternativeCount }
                .reduce(0) { $0 + max(0, $1.latest - $1.baseline) }
            let alternative = group.filter { $0.isAlternativeCount }
                .map { max(0, $0.latest - $0.baseline) }.max() ?? 0
            return total + max(library, alternative)
        }
        let calculated = initialCredit + increase
        count = max(count, calculated)
    }

    private var counterGroups: [[Counter]] {
        var groups: [[Counter]] = []
        for counter in counters {
            var group = [counter]
            // Only fallback evidence links alternative counter sources. Two
            // distinct library records retain their existing additive meaning.
            var merged = true
            while merged {
                merged = false
                for index in groups.indices.reversed() where groups[index].contains(where: { left in
                    group.contains { right in
                        (left.isAlternativeCount || right.isAlternativeCount)
                            && !Set((left.aliases ?? []) + [left.musicItemID])
                                .isDisjoint(with: (right.aliases ?? []) + [right.musicItemID])
                    }
                }) {
                    group += groups.remove(at: index)
                    merged = true
                }
            }
            groups.append(group)
        }
        return groups
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
                    // Coverage belongs to the selected initialization credit,
                    // just like its baseline. Unioning a later aggregate's
                    // coverage into an earlier credit would hide donor credit.
                    seeds[seed.id] = canonical
                } else { seeds[seed.id] = seed }
            }
            for counter in state.counters {
                if let existing = counters[counter.musicItemID] {
                    var canonical = (existing.firstObservedAt, existing.baselineID) < (counter.firstObservedAt, counter.baselineID)
                        ? existing : counter
                    canonical.latest = max(existing.latest, counter.latest)
                    let aliases = Array(Set((existing.aliases ?? []) + (counter.aliases ?? []))).sorted()
                    canonical.aliases = aliases.isEmpty ? nil : aliases
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
        var groups: [(ids: Set<String>, origins: Set<UUID>, credit: Int)] = []
        let alternatives = counterGroups.map { Set($0.map(\.musicItemID)) }
        // Unknown identities must not be assumed independent. Their published
        // individual floor is already preserved by the join; defer addition
        // until evidence binds them to a concrete counter.
        for seed in seeds where !seed.musicItemIDs.isEmpty {
            var group = (ids: Set(seed.musicItemIDs), origins: Set([seed.id] + (seed.coveredOriginIDs ?? [])), credit: seed.count)
            for ids in alternatives where !ids.isDisjoint(with: group.ids) { group.ids.formUnion(ids) }
            for index in groups.indices.reversed() where !groups[index].ids.isDisjoint(with: group.ids)
                || !groups[index].origins.isDisjoint(with: group.origins) {
                group.ids.formUnion(groups[index].ids)
                group.origins.formUnion(groups[index].origins)
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
