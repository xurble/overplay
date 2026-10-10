import Foundation
import MusicKit
import SwiftData

/// Refreshes all retained tracks, including retired tracks and tracks missing
/// from their remote playlist. Apple counts are independent of playlist edits.
@MainActor
final class ApplePlayCountSyncService {
    static let shared = ApplePlayCountSyncService(minimumRefreshInterval: 15)

    private let fetch: ([String]) async throws -> [MusicLibraryPlaybackObservation]
    private let saveChanges: (ModelContext) throws -> Void
    private let fetchLibrary: (String?) async throws -> [ApplePlayCountLibraryEntry]
    private let fetchPlaylist: (String) async throws -> [MusicLibraryPlaybackObservation]
    private let fetchRecentlyPlayed: () async throws -> [MusicLibraryPlaybackObservation]
    private let logRecentLookup: (String) -> Void
    private var isRefreshing = false
    private let minimumRefreshInterval: TimeInterval
    private var lastRefreshAt: Date?
    private var playlistInFlight: [String: Task<(Date, [MusicLibraryPlaybackObservation]), Error>] = [:]
    private var playlistAttempts: [String: Date] = [:]
    private var lastDiscoveryAt: Date?
    private var priorityInFlight = Set<UUID>()
    private var priorityAttempts: [UUID: Date] = [:]
    private var playlistResults: [String: (date: Date, observations: [MusicLibraryPlaybackObservation])] = [:]
    private var recentResult: (date: Date, observations: [MusicLibraryPlaybackObservation])?
    private var recentAttemptAt: Date?
    /// Bulk work waits out the launch rush: its apply step runs on the main
    /// actor, and statistics never compete with the first screens for it.
    private let readyAt: ContinuousClock.Instant?
    private var pendingReconcile: Task<Void, Never>?
    /// Items applied between yields, so a full pass never blocks a frame for long.
    private static let applySliceSize = 100

    init(minimumRefreshInterval: TimeInterval = 0, saveChanges: @escaping (ModelContext) throws -> Void = { try $0.save() },
         fetchRecentlyPlayed: @escaping () async throws -> [MusicLibraryPlaybackObservation] = {
        guard MusicAuthorization.currentStatus == .authorized else { return [] }
        return try await MusicKitLibraryPlaybackHistoryFetcher().recentlyPlayedObservations()
    },
         logRecentLookup: @escaping (String) -> Void = { detail in
        MusicKitActivityLog.shared.record(.playCountLookupResult, detail: detail)
    },
         fetchPlaylist: @escaping (String) async throws -> [MusicLibraryPlaybackObservation] = { id in
        guard MusicAuthorization.currentStatus == .authorized else { return [] }
        return try await MusicKitLibraryPlaybackHistoryFetcher().playlistObservations(for: id)
    },
         fetchLibrary: @escaping (String?) async throws -> [ApplePlayCountLibraryEntry] = { title in
        guard MusicAuthorization.currentStatus == .authorized else { return [] }
        return try await MusicKitLibraryPlaybackHistoryFetcher().libraryEntries(matching: title)
    },
         fetch: @escaping ([String]) async throws -> [MusicLibraryPlaybackObservation] = { ids in
        guard MusicAuthorization.currentStatus == .authorized else { return [] }
        return try await MusicKitLibraryPlaybackHistoryFetcher().observations(for: ids)
    }) {
        self.minimumRefreshInterval = minimumRefreshInterval
        self.fetch = fetch
        self.saveChanges = saveChanges
        self.fetchLibrary = fetchLibrary
        self.fetchPlaylist = fetchPlaylist
        self.fetchRecentlyPlayed = fetchRecentlyPlayed
        self.logRecentLookup = logRecentLookup
        self.readyAt = minimumRefreshInterval > 0 ? .now + .seconds(10) : nil
    }

    @discardableResult
    func refresh(in context: ModelContext, playbackController: PlaybackController? = nil) async -> Int {
        guard !isRefreshing, lastRefreshAt.map({ Date.now.timeIntervalSince($0) >= minimumRefreshInterval }) ?? true else {
            MusicKitActivityLog.shared.record(.playCountRefreshSkipped)
            return 0
        }
        lastRefreshAt = .now
        let span = PerformanceSpan(.playCountRefresh)
        defer { span.finish() }
        isRefreshing = true
        defer { isRefreshing = false }
        if let readyAt, ContinuousClock.now < readyAt {
            try? await Task.sleep(until: readyAt)
            guard !Task.isCancelled else { return 0 }
        }
        let startedAt = Date.now
        let reconciled: Int
        do {
            reconciled = try await persist([], startedAt: .now, in: context)
            playbackController?.refreshPlayCountMetadata(context: context)
        } catch {
            TrackMetadataDiagnostics.log("Apple play count reconciliation failed: \(error.localizedDescription)")
            reconciled = 0
        }
        do {
            let tracks = try TrackRecordRepository.allTracks(in: context)
            let items = try PlaylistItemRepository.allItems(in: context)
            let retainedIDs = Set(items.map(\.trackID))
            let ids = ApplePlayCountRepository.withSnapshot(for: items, in: context) {
                Set(tracks.filter { retainedIDs.contains($0.id) }.flatMap { PlaybackQueueBuilder.musicItemIDs(for: $0) })
                    .union(items.flatMap { $0.applePlayCountState?.counters.filter { !$0.isAlternativeCount }.map(\.musicItemID) ?? [] }).sorted()
            }
            var observations: [MusicLibraryPlaybackObservation] = []
            for start in stride(from: 0, to: ids.count, by: 100) {
                try Task.checkCancellation()
                observations += try await fetch(Array(ids[start..<min(start + 100, ids.count)]))
            }
            try Task.checkCancellation()
            var changed = try await persist(observations, startedAt: startedAt, in: context)
            let unresolved = try unresolvedTracks(in: context)
            if !unresolved.isEmpty, BackgroundMusicKitWorkPolicy.allowsLibraryDiscovery(
                lastDiscoveryAt: lastDiscoveryAt, now: startedAt, isPlaying: playbackController?.isPlaying ?? false
            ) {
                lastDiscoveryAt = startedAt
                do {
                    let library = try await fetchLibrary(nil)
                    try Task.checkCancellation()
                    let discoverySpan = PerformanceSpan(.playCountDiscovery)
                    defer { discoverySpan.finish(magnitude: Double(unresolved.count), detail: "library entries=\(library.count)") }
                    let index = await Task.detached(priority: .utility) { ApplePlayCountMatcher.Index(library) }.value
                    var discovered: [MusicLibraryPlaybackObservation] = []
                    for track in unresolved {
                        try Task.checkCancellation()
                        discovered += Self.discover(track, index: index)
                        // Let playback and its priority lookup run between
                        // matches even for a large retained library.
                        await Task.yield()
                    }
                    changed += try await persist(discovered, startedAt: startedAt, in: context)
                } catch {
                    TrackMetadataDiagnostics.log("Apple play count discovery failed: \(error.localizedDescription)")
                }
            }
            changed += await refreshPlaylistCounts(in: context, startedAt: startedAt)
            changed += await refreshRecentCounts(in: context, startedAt: startedAt)
            playbackController?.refreshPlayCountMetadata(context: context)
            return reconciled + changed
        } catch {
            // Failed/missing library metadata never substitutes zero or moves
            // an established baseline. A subsequent foreground/sync retries.
            TrackMetadataDiagnostics.log("Apple play count refresh failed: \(error.localizedDescription)")
            var changed = await refreshPlaylistCounts(in: context, startedAt: startedAt)
            changed += await refreshRecentCounts(in: context, startedAt: startedAt)
            playbackController?.refreshPlayCountMetadata(context: context)
            return reconciled + changed
        }
    }

    /// Independent of the bulk-refresh gate: a newly playing song must not
    /// wait behind hundreds of unrelated tracks or the discovery cooldown.
    @discardableResult
    func refreshCurrentTrack(_ trackID: UUID, in context: ModelContext, now: Date = .now) async -> Int {
        guard !priorityInFlight.contains(trackID),
              priorityAttempts[trackID].map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return 0 }
        priorityInFlight.insert(trackID)
        priorityAttempts[trackID] = now
        defer { priorityInFlight.remove(trackID) }
        var changed = 0
        do {
            guard let track = try unresolvedTracks(in: context).first(where: { $0.id == trackID }) else { return 0 }
            let observations = try await fetch(PlaybackQueueBuilder.musicItemIDs(for: track))
            try Task.checkCancellation()
            changed += try await persist(observations, startedAt: now, in: context)
            guard let remaining = try unresolvedTracks(in: context).first(where: { $0.id == trackID }) else { return changed }
            let title = remaining.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let library = try await fetchLibrary(title)
                try Task.checkCancellation()
                // A title-filtered result cannot prove ISRC uniqueness across
                // other album titles. Use identity/complete metadata here; the
                // periodic full scan can use the recording-code fallback.
                changed += try await persist(Self.discover(remaining, in: library, allowRecordingCode: false), startedAt: now, in: context)
            }
        } catch {
            TrackMetadataDiagnostics.log("Current-track Apple play count lookup failed: \(error.localizedDescription)")
        }
        changed += await refreshPlaylistCounts(in: context, startedAt: now, trackID: trackID)
        changed += await refreshRecentCounts(in: context, startedAt: now, trackID: trackID)
        return changed
    }

    /// Probe unresolved songs and keep refreshing any counters learned here.
    /// Recent history is incomplete, so use exact identities only. A song's
    /// absence (or nil count) is not evidence of zero or of a completed play.
    private func refreshRecentCounts(in context: ModelContext, startedAt: Date, trackID: UUID? = nil) async -> Int {
        guard !Task.isCancelled else { return 0 }
        do {
            let candidates = try PlaylistItemRepository.allItems(in: context)
            let items = ApplePlayCountRepository.withSnapshot(for: candidates, in: context) {
                candidates.filter { item in
                    (trackID == nil || item.trackID == trackID)
                        && (item.applePlayCount == nil || item.applePlayCountState?.counters.contains { $0.isRecentlyPlayedCount == true } == true)
                }
            }
            let ids = Set(items.map(\.trackID))
            guard !ids.isEmpty else { return 0 }
            let result: (date: Date, observations: [MusicLibraryPlaybackObservation])
            if let recentAttemptAt, startedAt.timeIntervalSince(recentAttemptAt) < 60 {
                guard let recentResult, recentResult.date == recentAttemptAt else { return 0 }
                result = recentResult
            } else {
                recentAttemptAt = startedAt
                let observations = try await fetchRecentlyPlayed()
                try Task.checkCancellation()
                result = (startedAt, observations)
                recentResult = result
            }
            // Re-resolve tracks after awaiting: sync may have merged/deleted them.
            let tracks = try TrackRecordRepository.allTracks(in: context).filter { ids.contains($0.id) }
            var matched: [MusicLibraryPlaybackObservation] = []
            var details: [String] = []
            for track in tracks {
                let aliases = Set(PlaybackQueueBuilder.musicItemIDs(for: track)
                    + items.filter { !$0.isDeleted && $0.trackID == track.id }
                        .flatMap { $0.applePlayCountState?.counters.flatMap { $0.aliases ?? [] } ?? [] })
                let found = result.observations.filter {
                    !aliases.isDisjoint(with: $0.aliases + [$0.snapshot.musicItemID])
                }
                matched += found.map {
                    var observation = $0
                    observation.matchedTrackID = track.id
                    observation.snapshot.recentlyPlayedEvidence = true
                    observation.snapshot.playlistEntryEvidence = nil
                    return observation
                }
                if details.count < 20 {
                    let counts = found.map { $0.snapshot.playCount.map(String.init) ?? "nil" }.joined(separator: ",")
                    details.append("\(track.title) [\(track.id)]: \(found.isEmpty ? "not returned" : "count=" + counts)")
                }
            }
            logRecentLookup("Recently played count probe: \(result.observations.count) songs returned; \(tracks.count) targets; "
                + details.joined(separator: "; "))
            return try await persist(matched, startedAt: result.date, in: context)
        } catch {
            if !Task.isCancelled {
                logRecentLookup("Recently played count probe failed: \(error.localizedDescription)")
            }
            return 0
        }
    }

    /// Fetch only source playlists needed by tracks without a library counter
    /// or already using playlist evidence. Do not trust playlist modification
    /// dates: listening can change a count without changing its membership.
    private func refreshPlaylistCounts(in context: ModelContext, startedAt: Date, trackID: UUID? = nil) async -> Int {
        guard !Task.isCancelled else { return 0 }
        var changed = 0
        do {
            let candidates = try PlaylistItemRepository.allItems(in: context)
            let items = ApplePlayCountRepository.withSnapshot(for: candidates, in: context) {
                candidates.filter { item in
                    guard trackID == nil || item.trackID == trackID else { return false }
                    let counters = item.applePlayCountState?.counters ?? []
                    return counters.isEmpty || counters.contains { $0.isAlternativeCount }
                }
            }
            let playlists = try PlaylistRepository.allPlaylists(in: context).firstValueDictionary(keyedBy: \.id)
            let ids = Set(items.flatMap { item in
                item.sourceMusicPlaylistIDs + item.entryProvenance.map(\.playlistID)
                    + [playlists[item.playlistID]?.musicPlaylistID].compactMap { $0 }
            }).filter { !$0.isEmpty && $0 != PlaylistRecord.triageBucketMusicPlaylistID }.sorted()
            // One apply and save per lookup date, not per playlist: each save
            // re-renders every surface showing playlist items.
            var pending: [Date: [MusicLibraryPlaybackObservation]] = [:]
            for id in ids {
                try Task.checkCancellation()
                do {
                    guard let result = try await playlistObservations(id, startedAt: startedAt) else { continue }
                    try Task.checkCancellation()
                    let observations = result.1
                    pending[result.0, default: []] += observations
                    TrackMetadataDiagnostics.log("Playlist Apple play counts: \(id), \(observations.count) songs, \(observations.filter { $0.snapshot.playCount != nil }.count) counts")
                } catch {
                    if Task.isCancelled { break }
                    TrackMetadataDiagnostics.log("Playlist Apple play count lookup failed: \(error.localizedDescription)")
                }
            }
            for (date, observations) in pending.sorted(by: { $0.key < $1.key }) {
                changed += try await persist(observations, startedAt: date, in: context)
            }
        } catch {
            TrackMetadataDiagnostics.log("Playlist Apple play count refresh failed: \(error.localizedDescription)")
        }
        return changed
    }

    private func playlistObservations(_ id: String, startedAt: Date) async throws -> (Date, [MusicLibraryPlaybackObservation])? {
        if let cached = playlistResults[id], startedAt.timeIntervalSince(cached.date) < 60 {
            return (cached.date, cached.observations)
        }
        if let task = playlistInFlight[id] { return try await task.value }
        if let attempted = playlistAttempts[id], startedAt.timeIntervalSince(attempted) < 60 { return nil }
        playlistAttempts[id] = startedAt
        let task = Task { (startedAt, try await fetchPlaylist(id)) }
        playlistInFlight[id] = task
        defer { playlistInFlight[id] = nil }
        let result = try await task.value
        playlistResults[id] = (result.0, result.1)
        return result
    }

    private func unresolvedTracks(in context: ModelContext) throws -> [TrackRecord] {
        let items = try PlaylistItemRepository.allItems(in: context)
        let ids = ApplePlayCountRepository.withSnapshot(for: items, in: context) {
            Set(items.filter { $0.applePlayCount == nil }.map(\.trackID))
        }
        return try TrackRecordRepository.allTracks(in: context).filter { ids.contains($0.id) }
    }

    private static func discover(_ track: TrackRecord, in library: [ApplePlayCountLibraryEntry],
                                 allowRecordingCode: Bool = true) -> [MusicLibraryPlaybackObservation] {
        discover(track, index: ApplePlayCountMatcher.Index(library), allowRecordingCode: allowRecordingCode)
    }

    private static func discover(_ track: TrackRecord, index: ApplePlayCountMatcher.Index,
                                 allowRecordingCode: Bool = true) -> [MusicLibraryPlaybackObservation] {
        guard !track.isDeleted else { return [] }
        let target = ApplePlayCountMatchTrack(aliases: PlaybackQueueBuilder.musicItemIDs(for: track),
            title: track.title, artist: track.artistName, album: track.albumTitle,
            duration: track.durationSeconds, isrc: track.isrc)
        return index.matches(target, allowRecordingCode: allowRecordingCode).map {
            var observation = $0
            observation.matchedTrackID = track.id
            observation.aliases = Array(Set(observation.aliases + target.aliases)).sorted()
            return observation
        }
    }

    /// CloudKit imports do not depend on authorization or a successful MusicKit
    /// request. Recompute from durable evidence and publish to every surface.
    @discardableResult
    func reconcile(in context: ModelContext, playbackController: PlaybackController? = nil) -> Int {
        // An import landing during launch reconciles once the launch rush is over.
        if let readyAt, ContinuousClock.now < readyAt {
            guard pendingReconcile == nil else { return 0 }
            pendingReconcile = Task { [weak self] in
                try? await Task.sleep(until: readyAt)
                self?.pendingReconcile = nil
                self?.reconcile(in: context, playbackController: playbackController)
            }
            return 0
        }
        do {
            let changed = try persistNow([], startedAt: .now, in: context)
            playbackController?.refreshPlayCountMetadata(context: context)
            return changed
        } catch {
            TrackMetadataDiagnostics.log("Apple play count reconciliation failed: \(error.localizedDescription)")
            return 0
        }
    }

    /// Applies in slices with yields between them, then saves once.
    private func persist(_ observations: [MusicLibraryPlaybackObservation], startedAt: Date,
                         in context: ModelContext) async throws -> Int {
        let pendingIDs = Set(context.insertedModelsArray.compactMap { ($0 as? ApplePlayCountRecord)?.id })
        let previous = try PlaylistItemRepository.allItems(in: context).map {
            (item: $0, activity: $0.hasRecordedActivity, updatedAt: $0.updatedAt)
        }
        let span = PerformanceSpan(.playCountApply)
        defer { span.finish(magnitude: Double(previous.count), detail: "sliced") }
        let prepared = Self.prepare(observations)
        let tracks = try TrackRecordRepository.allTracks(in: context).firstValueDictionary(keyedBy: \.id)
        var changed = 0
        for start in stride(from: 0, to: previous.count, by: Self.applySliceSize) {
            // Re-check each slice: items can be deleted while this yields.
            let slice = previous[start..<min(start + Self.applySliceSize, previous.count)].map(\.item).filter { !$0.isDeleted }
            changed += try ApplePlayCountRepository.withSnapshot(for: slice, in: context) {
                try Self.applyItems(slice, prepared: prepared, tracks: tracks, startedAt: startedAt, in: context)
            }
            await Task.yield()
        }
        return try save(changed: changed, pendingIDs: pendingIDs, previous: previous, in: context)
    }

    private func persistNow(_ observations: [MusicLibraryPlaybackObservation], startedAt: Date,
                            in context: ModelContext) throws -> Int {
        let pendingIDs = Set(context.insertedModelsArray.compactMap { ($0 as? ApplePlayCountRecord)?.id })
        let previous = try PlaylistItemRepository.allItems(in: context).map {
            (item: $0, activity: $0.hasRecordedActivity, updatedAt: $0.updatedAt)
        }
        let changed = try Self.apply(observations, startedAt: startedAt, in: context)
        return try save(changed: changed, pendingIDs: pendingIDs, previous: previous, in: context)
    }

    private func save(changed: Int, pendingIDs: Set<UUID>,
                      previous: [(item: PlaylistItemRecord, activity: Bool, updatedAt: Date)],
                      in context: ModelContext) throws -> Int {
        if changed > 0 {
            do { try saveChanges(context) }
            catch {
                for record in context.insertedModelsArray.compactMap({ $0 as? ApplePlayCountRecord })
                    where !pendingIDs.contains(record.id) {
                    context.delete(record)
                }
                for old in previous where !old.item.isDeleted {
                    old.item.hasRecordedActivity = old.activity
                    old.item.updatedAt = old.updatedAt
                }
                throw error
            }
        }
        return changed
    }

    @discardableResult
    static func apply(_ observations: [MusicLibraryPlaybackObservation], startedAt: Date,
                      in context: ModelContext) throws -> Int {
        let items = try PlaylistItemRepository.allItems(in: context)
        let span = PerformanceSpan(.playCountApply)
        defer { span.finish(magnitude: Double(items.count)) }
        return try ApplePlayCountRepository.withSnapshot(for: items, in: context) {
            try applyUsingSnapshot(observations, startedAt: startedAt, items: items, in: context)
        }
    }

    private static func applyUsingSnapshot(_ observations: [MusicLibraryPlaybackObservation], startedAt: Date,
                                          items: [PlaylistItemRecord], in context: ModelContext) throws -> Int {
        // Resolve identities again after the await: merges and new aliases may
        // have changed ownership while the library request was outstanding.
        let tracks = try TrackRecordRepository.allTracks(in: context).firstValueDictionary(keyedBy: \.id)
        return try applyItems(items, prepared: prepare(observations), tracks: tracks, startedAt: startedAt, in: context)
    }

    private struct PreparedObservations {
        var byAlias: [String: [MusicLibraryPlaybackObservation]]
        var byTrack: [UUID: [MusicLibraryPlaybackObservation]]
    }

    private static func prepare(_ observations: [MusicLibraryPlaybackObservation]) -> PreparedObservations {
        var countersByID: [String: MusicLibraryPlaybackObservation] = [:]
        for var observation in observations {
            guard let count = observation.snapshot.playCount, count >= 0 else { continue }
            if observation.snapshot.playlistEntryEvidence == true || observation.snapshot.recentlyPlayedEvidence == true {
                // Key by song, never by playlist occurrence. Keep the source
                // separate from library totals, which may have a different base.
                observation.aliases = Array(Set(observation.aliases + [observation.snapshot.musicItemID])).sorted()
                let prefix = observation.snapshot.recentlyPlayedEvidence == true ? "recent-count:" : "playlist-count:"
                observation.snapshot.musicItemID = prefix + observation.snapshot.musicItemID
            }
            let id = observation.snapshot.musicItemID + "/" + (observation.matchedTrackID?.uuidString ?? "")
            if var existing = countersByID[id] {
                existing.snapshot.playCount = max(existing.snapshot.playCount ?? 0, count)
                existing.aliases = Array(Set(existing.aliases + observation.aliases)).sorted()
                countersByID[id] = existing
            } else {
                countersByID[id] = observation
            }
        }
        var observationsByAlias: [String: [MusicLibraryPlaybackObservation]] = [:]
        var observationsByTrack: [UUID: [MusicLibraryPlaybackObservation]] = [:]
        for observation in countersByID.values {
            if let trackID = observation.matchedTrackID {
                observationsByTrack[trackID, default: []].append(observation)
                continue
            }
            for alias in Set(observation.aliases + [observation.snapshot.musicItemID]) {
                observationsByAlias[alias, default: []].append(observation)
            }
        }
        return PreparedObservations(byAlias: observationsByAlias, byTrack: observationsByTrack)
    }

    private static func applyItems(_ items: [PlaylistItemRecord], prepared: PreparedObservations,
                                   tracks: [UUID: TrackRecord], startedAt: Date, in context: ModelContext) throws -> Int {
        let observationsByAlias = prepared.byAlias
        let observationsByTrack = prepared.byTrack
        var changed = 0
        for item in items {
            guard let track = tracks[item.trackID], !track.isDeleted else { continue }
            let previous = item.applePlayCountState
            guard previous.map({ $0.resetID.isEmpty || $0.resetAt <= startedAt }) ?? true else { continue }
            let aliases = Set(PlaybackQueueBuilder.musicItemIDs(for: track)
                + (previous?.counters.map(\.musicItemID) ?? []))
            var state = previous
            let matched = aliases.sorted().flatMap({ observationsByAlias[$0] ?? [] }) + (observationsByTrack[track.id] ?? [])
            for observation in matched {
                guard let count = observation.snapshot.playCount, count >= 0 else { continue }
                if state == nil { state = ApplePlayCountState(initialCount: item.playthroughCount, originID: item.id) }
                state?.prepareFirstObservation(initialCount: item.playthroughCount, originID: item.id,
                                               musicItemID: observation.snapshot.musicItemID)
                state?.observe(musicItemID: observation.snapshot.musicItemID, count: count, at: startedAt,
                               aliases: observation.aliases, isPlaylistCount: observation.snapshot.playlistEntryEvidence == true,
                               isRecentlyPlayedCount: observation.snapshot.recentlyPlayedEvidence == true)
            }
            state?.advance()
            let displayedCount = state?.counters.isEmpty == false ? state?.count : nil
            if state != previous || displayedCount != item.applePlayCount {
                item.applePlayCountState = state
                if (state?.count ?? 0) > 0 { item.hasRecordedActivity = true }
                item.updatedAt = .now
                changed += 1
            }
        }
        return changed
    }
}
