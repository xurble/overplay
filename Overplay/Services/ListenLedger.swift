import Foundation
import SwiftData

/// The only writer of play and skip counts (`COUNT-002`).
///
/// Outcomes are appended as immutable `ListenEvent`s. A track's counts are a
/// pure function of the events for its own UUID and every UUID it absorbed in
/// an identity merge (lineage is itself recorded as immutable events), so two
/// devices holding the same events always derive the same numbers.
/// `PlaylistItemRecord.skipCount`/`playthroughCount` are only a cache of that
/// derivation, marked `countsDerivedFromLedger` when written; nothing
/// increments, sums or zeroes them directly.
@MainActor
enum ListenLedger {
    struct Counts: Equatable, Sendable {
        var playthroughs = 0
        var skips = 0
    }

    /// Value copy of an event, so derivation is testable without SwiftData.
    struct Entry: Equatable, Sendable {
        var id: UUID
        var trackID: UUID
        var kind: ListenEventKind
        var sessionID: String
        var occurredAt: Date
        var playthroughDelta = 0
        var skipDelta = 0
    }

    /// `statsReset` events apply to every track and use this reserved ID.
    static let allTracksID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    static let deviceID: String = {
        let key = "overplay.listenLedgerDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    // MARK: - Writing

    /// Appends an outcome unless the same kind and session was already
    /// recorded. Returns whether an event was inserted. Callers save.
    ///
    /// A track's first per-track event first carries its pre-ledger counts
    /// forward, so the new event adds to them instead of replacing them.
    @discardableResult
    static func record(
        _ kind: ListenEventKind,
        trackID: UUID,
        sessionID: String,
        source: ListenEventSource,
        mechanism: String? = nil,
        playthroughDelta: Int = 0,
        skipDelta: Int = 0,
        at date: Date = .now,
        in context: ModelContext
    ) throws -> Bool {
        if kind != .baseline, trackID != allTracksID {
            try migrateLegacyCounts(forTrackIDs: [trackID], at: date.addingTimeInterval(-0.001), in: context)
        }
        return try insert(kind, trackID: trackID, sessionID: sessionID, source: source, mechanism: mechanism,
                          playthroughDelta: playthroughDelta, skipDelta: skipDelta, at: date, in: context)
    }

    /// Records that `keeper` absorbed `donor` (and, transitively, everything
    /// the donor had absorbed). Idempotent; callers save.
    static func recordLineage(keeper: UUID, donor: UUID, in context: ModelContext) throws {
        guard keeper != donor else { return }
        _ = try insert(.lineage, trackID: keeper, sessionID: "lineage:\(donor.uuidString)", source: .migration,
                       mechanism: nil, playthroughDelta: 0, skipDelta: 0, at: .now, in: context)
    }

    /// Restarts every track's counts. Retirement reset stays with the caller.
    static func resetAll(at date: Date = .now, in context: ModelContext) throws {
        try writeBaselinesIfNeeded(in: context, at: date.addingTimeInterval(-0.001))
        try record(.statsReset, trackID: allTracksID, sessionID: UUID().uuidString, source: .user, at: date, in: context)
        try refreshAllCounts(in: context)
    }

    /// Restarts one track's skip count and refreshes its items.
    static func resetSkips(trackID: UUID, at date: Date = .now, in context: ModelContext) throws {
        try record(.skipReset, trackID: trackID, sessionID: UUID().uuidString, source: .user, at: date, in: context)
        try refreshCounts(forTrackIDs: [trackID], in: context)
    }

    /// Carries pre-ledger counts forward for every track that still has them.
    @discardableResult
    static func writeBaselinesIfNeeded(in context: ModelContext, at date: Date = .now) throws -> Int {
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>()).filter { !$0.isDeleted }
        let trackIDs = Set(items.filter(hasLegacyCounts).map(\.trackID))
        return try migrateLegacyCounts(forTrackIDs: trackIDs, at: date, in: context)
    }

    /// Writes one `baseline:<trackID>` event holding a track's pre-ledger
    /// counts. Only rows the ledger has never written count as pre-ledger: a
    /// row marked `countsDerivedFromLedger` holds a derived cache, possibly
    /// synced from another device ahead of its events, and migrating it would
    /// count those plays twice. Tracks with outcome events already are left
    /// alone. Items of one track were separate counters before the ledger, so
    /// their counts are added. The deterministic session ID collapses
    /// migrations on several devices. Call before absorbing tracks, so each
    /// identity migrates on its own.
    @discardableResult
    static func migrateLegacyCounts(forTrackIDs trackIDs: Set<UUID>, at date: Date = .now, in context: ModelContext) throws -> Int {
        let candidates = trackIDs.subtracting([allTracksID])
        guard !candidates.isEmpty else { return 0 }
        let ids = Array(candidates)
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>(predicate: #Predicate {
            ids.contains($0.trackID)
        })).filter { !$0.isDeleted }
        let itemsByTrackID = Dictionary(grouping: items, by: \.trackID)
        var written = 0
        let lineage = ListenEventKind.lineage.rawValue
        for trackID in candidates {
            let trackItems = (itemsByTrackID[trackID] ?? []).filter(hasLegacyCounts)
            let plays = trackItems.reduce(0) { $0 + max($1.playthroughCount, 0) }
            let skips = trackItems.reduce(0) { $0 + max($1.skipCount, 0) }
            guard plays != 0 || skips != 0 else { continue }
            let identities = Array(try identities(for: trackID, in: context))
            var existing = FetchDescriptor<ListenEvent>(predicate: #Predicate {
                identities.contains($0.trackID) && $0.kindRawValue != lineage
            })
            existing.fetchLimit = 1
            guard try context.fetchCount(existing) == 0 else { continue }
            if try insert(.baseline, trackID: trackID, sessionID: "baseline:\(trackID.uuidString)", source: .migration, mechanism: nil,
                          playthroughDelta: plays, skipDelta: skips, at: date, in: context) {
                written += 1
            }
        }
        return written
    }

    private static func insert(
        _ kind: ListenEventKind,
        trackID: UUID,
        sessionID: String,
        source: ListenEventSource,
        mechanism: String?,
        playthroughDelta: Int,
        skipDelta: Int,
        at date: Date,
        in context: ModelContext
    ) throws -> Bool {
        let kindRawValue = kind.rawValue
        var descriptor = FetchDescriptor<ListenEvent>(predicate: #Predicate {
            $0.trackID == trackID && $0.sessionID == sessionID && $0.kindRawValue == kindRawValue
        })
        descriptor.fetchLimit = 1
        guard try context.fetchCount(descriptor) == 0 else { return false }
        context.insert(ListenEvent(
            trackID: trackID,
            kind: kind,
            sessionID: sessionID,
            deviceID: deviceID,
            source: source,
            mechanism: mechanism,
            playthroughDelta: playthroughDelta,
            skipDelta: skipDelta,
            occurredAt: date
        ))
        return true
    }

    /// Event counts at the last full recompute, per store. Unchanged events
    /// and no new migration mean every cache is already derived from them.
    private static var reconciledEventCounts: [ObjectIdentifier: Int] = [:]

    /// Startup and CloudKit-import entry point: migrate anything uncounted,
    /// then bring every item's cache in line with the ledger.
    @discardableResult
    static func reconcile(in context: ModelContext) throws -> Int {
        let migrated = try writeBaselinesIfNeeded(in: context)
        let store = ObjectIdentifier(context.container)
        let eventCount = try context.fetchCount(FetchDescriptor<ListenEvent>())
        guard migrated > 0 || reconciledEventCounts[store] != eventCount else { return 0 }
        let changed = try refreshAllCounts(in: context)
        reconciledEventCounts[store] = eventCount
        if migrated > 0 || changed > 0 {
            try context.save()
            TrackMetadataDiagnostics.log("listen ledger reconciled baselines=\(migrated) refreshedItems=\(changed)")
        }
        return changed
    }

    // MARK: - Deriving

    static func counts(forTrackID trackID: UUID, in context: ModelContext) throws -> Counts {
        let identities = try identities(for: trackID, in: context)
        return counts(identities: identities, entries: try entries(for: identities, in: context))
    }

    /// Updates the count cache of every item belonging to these tracks.
    @discardableResult
    static func refreshCounts(forTrackIDs trackIDs: Set<UUID>, in context: ModelContext) throws -> Int {
        guard !trackIDs.isEmpty else { return 0 }
        let ids = Array(trackIDs)
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>(predicate: #Predicate {
            ids.contains($0.trackID)
        })).filter { !$0.isDeleted }
        var changed = 0
        for trackID in trackIDs {
            let identities = try identities(for: trackID, in: context)
            let entries = try entries(for: identities, in: context)
            let derived = derivation(identities: identities, entries: entries)
            for item in items where item.trackID == trackID && apply(derived, to: item) {
                changed += 1
            }
        }
        return changed
    }

    /// Recomputes every item from one read of the ledger.
    @discardableResult
    static func refreshAllCounts(in context: ModelContext) throws -> Int {
        let items = try context.fetch(FetchDescriptor<PlaylistItemRecord>()).filter { !$0.isDeleted }
        guard !items.isEmpty else { return 0 }
        let tracksByID = try context.fetch(FetchDescriptor<TrackRecord>()).firstValueDictionary(keyedBy: \.id)
        let allEntries = try context.fetch(FetchDescriptor<ListenEvent>()).compactMap(entry(for:))
        let globalResets = allEntries.filter { $0.trackID == allTracksID }
        let entriesByTrackID = Dictionary(grouping: allEntries, by: \.trackID)
        var changed = 0
        for item in items {
            let identities = lineageClosure(of: item.trackID, tracksByID: tracksByID, entriesByTrackID: entriesByTrackID)
            let entries = identities.flatMap { entriesByTrackID[$0] ?? [] } + globalResets
            if apply(derivation(identities: identities, entries: entries), to: item) { changed += 1 }
        }
        return changed
    }

    /// Pure derivation. Playthroughs restart at the latest global reset; skips
    /// at the later of that and the track's own latest skip reset. Session IDs
    /// make every outcome idempotent; competing baselines for one session
    /// resolve deterministically to the earliest, then the lowest ID.
    struct Derivation: Equatable, Sendable {
        var counts: Counts
        var playsResetAt: Date?
        var skipsResetAt: Date?
    }

    /// Counts plus the reset floors they were derived after.
    nonisolated static func derivation(identities: Set<UUID>, entries: [Entry]) -> Derivation {
        let globalResetAt = entries.filter { $0.kind == .statsReset }.map(\.occurredAt).max()
        let skipResetAt = entries.filter { identities.contains($0.trackID) && $0.kind == .skipReset }.map(\.occurredAt).max()
        return Derivation(
            counts: counts(identities: identities, entries: entries),
            playsResetAt: globalResetAt,
            skipsResetAt: [globalResetAt, skipResetAt].compactMap { $0 }.max()
        )
    }

    /// Joins a cached count with a derived one. A later reset wins outright;
    /// with the same reset, the higher count is the more complete.
    nonisolated static func join(
        cached: (count: Int, resetAt: Date?),
        derived: (count: Int, resetAt: Date?)
    ) -> (count: Int, resetAt: Date?) {
        switch (cached.resetAt, derived.resetAt) {
        case let (cachedReset?, derivedReset?) where cachedReset > derivedReset: return cached
        case let (cachedReset?, derivedReset?) where cachedReset < derivedReset: return derived
        case (.some, nil): return cached
        case (nil, .some): return derived
        default: return (max(cached.count, derived.count), derived.resetAt)
        }
    }

    nonisolated static func counts(identities: Set<UUID>, entries: [Entry]) -> Counts {
        let globalResetAt = entries.filter { $0.kind == .statsReset }.map(\.occurredAt).max()
        let own = entries.filter { identities.contains($0.trackID) }
        let skipResetAt = own.filter { $0.kind == .skipReset }.map(\.occurredAt).max()
        let skipFloor = [globalResetAt, skipResetAt].compactMap { $0 }.max()
        func after(_ floor: Date?, _ entry: Entry) -> Bool { floor.map { entry.occurredAt > $0 } ?? true }

        var result = Counts()
        var seen = Set<String>()
        for entry in own {
            switch entry.kind {
            case .playthrough where after(globalResetAt, entry):
                if seen.insert("p:\(entry.sessionID)").inserted { result.playthroughs += 1 }
            case .skip where after(skipFloor, entry):
                if seen.insert("s:\(entry.sessionID)").inserted { result.skips += 1 }
            default:
                continue
            }
        }

        let baselines = Dictionary(grouping: own.filter { $0.kind == .baseline }, by: \.sessionID)
        for candidates in baselines.values {
            guard let chosen = candidates.min(by: {
                $0.occurredAt != $1.occurredAt ? $0.occurredAt < $1.occurredAt : $0.id.uuidString < $1.id.uuidString
            }) else { continue }
            if after(globalResetAt, chosen) { result.playthroughs += max(chosen.playthroughDelta, 0) }
            if after(skipFloor, chosen) { result.skips += max(chosen.skipDelta, 0) }
        }
        return result
    }

    // MARK: - Helpers

    /// The track plus everything it absorbed, transitively, from both the
    /// track's lineage list and immutable lineage events.
    private static func identities(for trackID: UUID, in context: ModelContext) throws -> Set<UUID> {
        let lineage = ListenEventKind.lineage.rawValue
        var result: Set<UUID> = [trackID]
        var pending: [UUID] = [trackID]
        while let next = pending.popLast() {
            var donors = try TrackRecordRepository.track(id: next, in: context)?.absorbedTrackUUIDs ?? []
            donors += try context.fetch(FetchDescriptor<ListenEvent>(predicate: #Predicate {
                $0.trackID == next && $0.kindRawValue == lineage
            })).compactMap { lineageDonor(sessionID: $0.sessionID) }
            for donor in donors where result.insert(donor).inserted { pending.append(donor) }
        }
        return result
    }

    /// The surviving track that absorbed `trackID`, following lineage until a
    /// track that still exists. Nil when nothing absorbed it.
    static func keeper(absorbing trackID: UUID, in context: ModelContext) throws -> UUID? {
        let lineage = ListenEventKind.lineage.rawValue
        var current = trackID
        var visited: Set<UUID> = [trackID]
        while true {
            let sessionID = "lineage:\(current.uuidString)"
            var descriptor = FetchDescriptor<ListenEvent>(predicate: #Predicate {
                $0.kindRawValue == lineage && $0.sessionID == sessionID
            })
            descriptor.fetchLimit = 1
            // Every merge writes a lineage event, so the immutable record is
            // enough; no scan of every track during playback.
            guard let keeper = try context.fetch(descriptor).first?.trackID,
                  visited.insert(keeper).inserted else { return nil }
            if try TrackRecordRepository.track(id: keeper, in: context) != nil { return keeper }
            current = keeper
        }
    }

    private static func lineageClosure(
        of trackID: UUID,
        tracksByID: [UUID: TrackRecord],
        entriesByTrackID: [UUID: [Entry]]
    ) -> Set<UUID> {
        var result: Set<UUID> = [trackID]
        var pending: [UUID] = [trackID]
        while let next = pending.popLast() {
            let donors = (tracksByID[next]?.absorbedTrackUUIDs ?? [])
                + (entriesByTrackID[next] ?? []).filter { $0.kind == .lineage }.compactMap { lineageDonor(sessionID: $0.sessionID) }
            for donor in donors where result.insert(donor).inserted { pending.append(donor) }
        }
        return result
    }

    nonisolated static func lineageDonor(sessionID: String) -> UUID? {
        guard sessionID.hasPrefix("lineage:") else { return nil }
        return UUID(uuidString: String(sessionID.dropFirst("lineage:".count)))
    }

    private static func hasLegacyCounts(_ item: PlaylistItemRecord) -> Bool {
        !item.countsDerivedFromLedger && (item.skipCount != 0 || item.playthroughCount != 0)
    }

    private static func entries(for identities: Set<UUID>, in context: ModelContext) throws -> [Entry] {
        let ids = Array(identities) + [allTracksID]
        return try context.fetch(FetchDescriptor<ListenEvent>(predicate: #Predicate {
            ids.contains($0.trackID)
        })).compactMap(entry(for:))
    }

    private static func entry(for event: ListenEvent) -> Entry? {
        guard let kind = event.kind else { return nil }
        return Entry(id: event.id, trackID: event.trackID, kind: kind, sessionID: event.sessionID,
                     occurredAt: event.occurredAt, playthroughDelta: event.playthroughDelta,
                     skipDelta: event.skipDelta)
    }

    /// Writes only real changes, and leaves `updatedAt` alone: the cache is
    /// derived, and must not look like a user decision to merge logic. The
    /// marker travels with the cache so no device mistakes it for legacy counts.
    ///
    /// A marked row is joined with the derivation instead of overwritten: a
    /// count that is higher than this store can explain came from a device
    /// whose events have not all arrived yet, and lowering it would publish a
    /// wrong count to every device, permanently lower an Apple play-count seed,
    /// or let the 0/0 retention rule delete a row whose history is in flight.
    /// Only a reset this store knows about, newer than the one the row
    /// reflects, can lower it.
    private static func apply(_ derived: Derivation, to item: PlaylistItemRecord) -> Bool {
        var plays = (count: derived.counts.playthroughs, resetAt: derived.playsResetAt)
        var skips = (count: derived.counts.skips, resetAt: derived.skipsResetAt)
        if item.countsDerivedFromLedger {
            plays = join(cached: (item.playthroughCount, item.countsPlaysResetAt), derived: plays)
            skips = join(cached: (item.skipCount, item.countsSkipsResetAt), derived: skips)
        }
        guard !item.countsDerivedFromLedger
            || item.playthroughCount != plays.count || item.skipCount != skips.count
            || item.countsPlaysResetAt != plays.resetAt || item.countsSkipsResetAt != skips.resetAt else { return false }
        item.playthroughCount = plays.count
        item.skipCount = skips.count
        item.countsPlaysResetAt = plays.resetAt
        item.countsSkipsResetAt = skips.resetAt
        item.countsDerivedFromLedger = true
        return true
    }
}
