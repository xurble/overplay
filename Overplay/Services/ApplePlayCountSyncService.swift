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
    private var isRefreshing = false
    private var lastDiscoveryAt: Date?
    private var priorityInFlight = Set<UUID>()
    private var priorityAttempts: [UUID: Date] = [:]

    init(saveChanges: @escaping (ModelContext) throws -> Void = { try $0.save() },
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
                .union(items.flatMap { $0.applePlayCountState?.counters.map(\.musicItemID) ?? [] })
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
            playbackController?.refreshPlayCountMetadata(context: context)
            return reconciled + changed
        } catch {
            // Failed/missing library metadata never substitutes zero or moves
            // an established baseline. A subsequent foreground/sync retries.
            TrackMetadataDiagnostics.log("Apple play count refresh failed: \(error.localizedDescription)")
            return reconciled
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
            guard !title.isEmpty else { return changed }
            let library = try await fetchLibrary(title)
            try Task.checkCancellation()
            // A title-filtered result cannot prove ISRC uniqueness across
            // other album titles. Use identity/complete metadata here; the
            // periodic full scan can use the recording-code fallback.
            changed += try persist(Self.discover(remaining, in: library, allowRecordingCode: false), startedAt: now, in: context)
        } catch {
            TrackMetadataDiagnostics.log("Current-track Apple play count lookup failed: \(error.localizedDescription)")
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
        for observation in observations where observation.snapshot.playlistEntryEvidence != true {
            guard let count = observation.snapshot.playCount, count >= 0 else { continue }
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
                state?.observe(musicItemID: observation.snapshot.musicItemID, count: count, at: startedAt)
            }
            state?.advance()
            if state != previous || state?.count != item.applePlayCount {
                item.applePlayCountState = state
                if (state?.count ?? 0) > 0 { item.hasRecordedActivity = true }
                item.updatedAt = .now
                changed += 1
            }
        }
        return changed
    }
}
