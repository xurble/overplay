import Foundation
import MusicKit
import SwiftData

/// Refreshes all retained tracks, including retired tracks and tracks missing
/// from their remote playlist. Apple counts are independent of playlist edits.
@MainActor
final class ApplePlayCountSyncService {
    static let shared = ApplePlayCountSyncService()

    private let fetch: ([String]) async throws -> [MusicLibraryPlaybackObservation]
    private let saveChanges: (ModelContext) throws -> Void
    private let fetchLibrary: (String?) async throws -> [ApplePlayCountLibraryEntry]
    private let fetchPlaylist: (String) async throws -> [MusicLibraryPlaybackObservation]
    private let fetchRecentlyPlayed: () async throws -> [MusicLibraryPlaybackObservation]
    private let logRecentLookup: (String) -> Void
    private var isRefreshing = false
    private var lastDiscoveryAt: Date?
    private var priorityInFlight = Set<UUID>()
    private var priorityAttempts: [UUID: Date] = [:]
    private var playlistResults: [String: (date: Date, observations: [MusicLibraryPlaybackObservation])] = [:]
    private var recentResult: (date: Date, observations: [MusicLibraryPlaybackObservation])?
    private var recentAttemptAt: Date?

    init(saveChanges: @escaping (ModelContext) throws -> Void = { try $0.save() },
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
        self.fetch = fetch
        self.saveChanges = saveChanges
        self.fetchLibrary = fetchLibrary
        self.fetchPlaylist = fetchPlaylist
        self.fetchRecentlyPlayed = fetchRecentlyPlayed
        self.logRecentLookup = logRecentLookup
    }

    @discardableResult
    func refresh(in context: ModelContext, playbackController: PlaybackController? = nil) async -> Int {
        guard !isRefreshing else { return 0 }
        isRefreshing = true
        defer { isRefreshing = false }
        let startedAt = Date.now
        let reconciled = reconcile(in: context, playbackController: playbackController)
        do {
            let tracks = try TrackRecordRepository.allTracks(in: context)
            let items = try PlaylistItemRepository.allItems(in: context)
            let retainedIDs = Set(items.map(\.trackID))
            let ids = Set(tracks.filter { retainedIDs.contains($0.id) }
                .flatMap { PlaybackQueueBuilder.musicItemIDs(for: $0) })
                .union(items.flatMap { $0.applePlayCountState?.counters.filter { !$0.isAlternativeCount }.map(\.musicItemID) ?? [] })
                .sorted()
            var observations: [MusicLibraryPlaybackObservation] = []
            for start in stride(from: 0, to: ids.count, by: 100) {
                try Task.checkCancellation()
                observations += try await fetch(Array(ids[start..<min(start + 100, ids.count)]))
            }
            try Task.checkCancellation()
            var changed = try persist(observations, startedAt: startedAt, in: context)
            let unresolved = try unresolvedTracks(in: context)
            if !unresolved.isEmpty, lastDiscoveryAt.map({ startedAt.timeIntervalSince($0) >= 15 * 60 }) ?? true {
                lastDiscoveryAt = startedAt
                do {
                    let library = try await fetchLibrary(nil)
                    try Task.checkCancellation()
                    var discovered: [MusicLibraryPlaybackObservation] = []
                    for track in unresolved {
                        try Task.checkCancellation()
                        discovered += Self.discover(track, in: library)
                        // Let playback and its priority lookup run between
                        // matches even for a large retained library.
                        await Task.yield()
                    }
                    changed += try persist(discovered, startedAt: startedAt, in: context)
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
            changed += try persist(observations, startedAt: now, in: context)
            guard let remaining = try unresolvedTracks(in: context).first(where: { $0.id == trackID }) else { return changed }
            let title = remaining.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let library = try await fetchLibrary(title)
                try Task.checkCancellation()
                // A title-filtered result cannot prove ISRC uniqueness across
                // other album titles. Use identity/complete metadata here; the
                // periodic full scan can use the recording-code fallback.
                changed += try persist(Self.discover(remaining, in: library, allowRecordingCode: false), startedAt: now, in: context)
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
            let items = try PlaylistItemRepository.allItems(in: context).filter { item in
                (trackID == nil || item.trackID == trackID)
                    && (item.applePlayCount == nil || item.applePlayCountState?.counters.contains {
                        $0.isRecentlyPlayedCount == true
                    } == true)
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
            return try persist(matched, startedAt: result.date, in: context)
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
            let items = try PlaylistItemRepository.allItems(in: context).filter { item in
                guard trackID == nil || item.trackID == trackID else { return false }
                let counters = item.applePlayCountState?.counters ?? []
                return counters.isEmpty || counters.contains { $0.isAlternativeCount }
            }
            let playlists = try PlaylistRepository.allPlaylists(in: context).firstValueDictionary(keyedBy: \.id)
            let ids = Set(items.flatMap { item in
                item.sourceMusicPlaylistIDs + item.entryProvenance.map(\.playlistID)
                    + [playlists[item.playlistID]?.musicPlaylistID].compactMap { $0 }
            }).filter { !$0.isEmpty && $0 != PlaylistRecord.triageBucketMusicPlaylistID }.sorted()
            for id in ids {
                try Task.checkCancellation()
                do {
                    let observations: [MusicLibraryPlaybackObservation]
                    if let cached = playlistResults[id], startedAt.timeIntervalSince(cached.date) < 60 {
                        // Never replay an observation captured before a stats reset.
                        changed += try persist(cached.observations, startedAt: cached.date, in: context)
                        continue
                    }
                    observations = try await fetchPlaylist(id)
                    try Task.checkCancellation()
                    playlistResults[id] = (startedAt, observations)
                    changed += try persist(observations, startedAt: startedAt, in: context)
                    TrackMetadataDiagnostics.log("Playlist Apple play counts: \(id), \(observations.count) songs, \(observations.filter { $0.snapshot.playCount != nil }.count) counts")
                } catch {
                    if Task.isCancelled { break }
                    TrackMetadataDiagnostics.log("Playlist Apple play count lookup failed: \(error.localizedDescription)")
                }
            }
        } catch {
            TrackMetadataDiagnostics.log("Playlist Apple play count refresh failed: \(error.localizedDescription)")
        }
        return changed
    }

    private func unresolvedTracks(in context: ModelContext) throws -> [TrackRecord] {
        let ids = Set(try PlaylistItemRepository.allItems(in: context).filter { $0.applePlayCount == nil }.map(\.trackID))
        return try TrackRecordRepository.allTracks(in: context).filter { ids.contains($0.id) }
    }

    private static func discover(_ track: TrackRecord, in library: [ApplePlayCountLibraryEntry],
                                 allowRecordingCode: Bool = true) -> [MusicLibraryPlaybackObservation] {
        guard !track.isDeleted else { return [] }
        let target = ApplePlayCountMatchTrack(aliases: PlaybackQueueBuilder.musicItemIDs(for: track),
            title: track.title, artist: track.artistName, album: track.albumTitle,
            duration: track.durationSeconds, isrc: track.isrc)
        return ApplePlayCountMatcher.matches(target, in: library, allowRecordingCode: allowRecordingCode).map {
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
        do {
            let changed = try persist([], startedAt: .now, in: context)
            playbackController?.refreshPlayCountMetadata(context: context)
            return changed
        } catch {
            TrackMetadataDiagnostics.log("Apple play count reconciliation failed: \(error.localizedDescription)")
            return 0
        }
    }

    private func persist(_ observations: [MusicLibraryPlaybackObservation], startedAt: Date,
                         in context: ModelContext) throws -> Int {
        let pendingIDs = Set(context.insertedModelsArray.compactMap { ($0 as? ApplePlayCountRecord)?.id })
        let previous = try PlaylistItemRepository.allItems(in: context).map {
            (item: $0, activity: $0.hasRecordedActivity, updatedAt: $0.updatedAt)
        }
        let changed = try Self.apply(observations, startedAt: startedAt, in: context)
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
        // Resolve identities again after the await: merges and new aliases may
        // have changed ownership while the library request was outstanding.
        let tracks = try TrackRecordRepository.allTracks(in: context).firstValueDictionary(keyedBy: \.id)
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
        var changed = 0
        for item in try PlaylistItemRepository.allItems(in: context) {
            guard let track = tracks[item.trackID],
                  item.applePlayCountResetAt.map({ $0 <= startedAt }) ?? true else { continue }
            let previous = item.applePlayCountState
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
