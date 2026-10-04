import Foundation
import SwiftData

/// The only writer of play and skip counts (`COUNT-002`).
///
/// Outcomes are appended as immutable `ListenEvent`s. A track's counts are a
/// pure function of the events for its own UUID and every UUID it absorbed in
/// an identity merge, so two devices holding the same events always derive the
/// same numbers. `PlaylistItemRecord.skipCount`/`playthroughCount` are only a
/// cache of that derivation; nothing increments, sums or zeroes them directly.
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
        let trackIDs = Set(items.filter { $0.skipCount != 0 || $0.playthroughCount != 0 }.map(\.trackID))
        return try migrateLegacyCounts(forTrackIDs: trackIDs, at: date, in: context)
    }

    /// Writes one `baseline:<trackID>` event holding a track's cached counts
    /// when no event exists for the track or anything it absorbed: until then
    /// the cache is the only record of those plays. Items of one track were
    /// separate counters before the ledger, so their counts are added. The
    /// deterministic session ID collapses migrations on several devices.
    /// Call before absorbing tracks, so each identity migrates on its own.
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
        for trackID in candidates {
            let trackItems = itemsByTrackID[trackID] ?? []
            let plays = trackItems.reduce(0) { $0 + max($1.playthroughCount, 0) }
            let skips = trackItems.reduce(0) { $0 + max($1.skipCount, 0) }
            guard plays != 0 || skips != 0 else { continue }
            let identities = Array(try identities(for: trackID, in: context))
            var existing = FetchDescriptor<ListenEvent>(predicate: #Predicate { identities.contains($0.trackID) })
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

    /// Startup and CloudKit-import entry point: migrate anything uncounted,
    /// then bring every item's cache in line with the ledger.
    @discardableResult
    static func reconcile(in context: ModelContext) throws -> Int {
        let migrated = try writeBaselinesIfNeeded(in: context)
        let changed = try refreshAllCounts(in: context)
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
            let derived = try counts(forTrackID: trackID, in: context)
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
            let identities = Set([item.trackID] + (tracksByID[item.trackID]?.absorbedTrackUUIDs ?? []))
            let entries = identities.flatMap { entriesByTrackID[$0] ?? [] } + globalResets
            if apply(counts(identities: identities, entries: entries), to: item) { changed += 1 }
        }
        return changed
    }

    /// Pure derivation. Playthroughs restart at the latest global reset; skips
    /// at the later of that and the track's own latest skip reset. Session IDs
    /// make every outcome idempotent; competing baselines for one session keep
    /// the largest carried-forward total, which is the most complete one.
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
            guard let chosen = candidates.max(by: {
                let left = $0.playthroughDelta + $0.skipDelta, right = $1.playthroughDelta + $1.skipDelta
                return left != right ? left < right : $0.id.uuidString > $1.id.uuidString
            }) else { continue }
            if after(globalResetAt, chosen) { result.playthroughs += max(chosen.playthroughDelta, 0) }
            if after(skipFloor, chosen) { result.skips += max(chosen.skipDelta, 0) }
        }
        return result
    }

    // MARK: - Helpers

    private static func identities(for trackID: UUID, in context: ModelContext) throws -> Set<UUID> {
        let track = try TrackRecordRepository.track(id: trackID, in: context)
        return Set([trackID] + (track?.absorbedTrackUUIDs ?? []))
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
    /// derived, and must not look like a user decision to merge logic.
    private static func apply(_ counts: Counts, to item: PlaylistItemRecord) -> Bool {
        guard item.playthroughCount != counts.playthroughs || item.skipCount != counts.skips else { return false }
        item.playthroughCount = counts.playthroughs
        item.skipCount = counts.skips
        return true
    }
}
