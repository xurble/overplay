import Foundation
import SwiftData

/// Reconciles playback that happened while Overplay was suspended and picks
/// the next background wake target. Runs on every wake: a background
/// refresh grant, scene foregrounding, and just before suspension (which
/// records the exact baseline waypoint).
@MainActor
enum PlaybackReconciliationService {
    private static let maxPendingMusicLibraryBaselines = 12

    struct Result {
        var countedLocalTrackIDs: [String] = []
        var nextWakeTarget: Date?
    }

    /// Computes the aimed wake synchronously so entering the background can
    /// submit it before awaiting the supporting MusicKit metadata request.
    static func nextWakeTarget(
        playbackController: PlaybackController,
        context: ModelContext
    ) -> Date? {
        guard let observation = playbackController.capturePlaybackObservation(context: context) else {
            return nil
        }
        let threshold = (try? SettingsRepository.settings(in: context))?
            .playthroughThresholdPercentage ?? 90
        let orderedTracks = orderedTracks(
            playlistID: observation.playlistID,
            playerID: playbackController.playerID,
            scope: playbackController.currentPlaylistScope,
            context: context
        )
        return nextWakeTarget(
            observation: observation,
            orderedTracks: orderedTracks,
            playthroughThresholdPercentage: threshold
        )
    }

    @discardableResult
    static func reconcileAndCaptureWaypoint(
        playbackController: PlaybackController,
        context: ModelContext,
        musicLibraryFetcher: any MusicLibraryPlaybackHistoryFetching = MusicKitLibraryPlaybackHistoryFetcher()
    ) async -> Result {
        guard let observation = playbackController.capturePlaybackObservation(context: context) else {
            // Nothing observable (no queue, or an unresolvable track). Keep
            // the existing waypoint — a later wake may still reconcile
            // against it, and overwriting it here would destroy the baseline.
            return Result()
        }

        let waypoint = PlaybackWaypointStore.load()
        let settings = try? SettingsRepository.settings(in: context)
        let threshold = settings?.playthroughThresholdPercentage ?? 90
        let orderedTracks = orderedTracks(
            playlistID: observation.playlistID,
            playerID: playbackController.playerID,
            scope: playbackController.currentPlaylistScope,
            context: context
        )
        let candidateLocalTrackIDs = Set([
            waypoint?.localTrackID,
            observation.localTrackID
        ].compactMap { $0 }).union(
            waypoint?.allMusicLibraryBaselines.map(\.localTrackID) ?? []
        )
        let candidates = musicLibraryCandidates(
            localTrackIDs: candidateLocalTrackIDs,
            context: context
        )
        let musicLibrarySnapshots: [String: MusicLibraryPlaybackSnapshot]
        do {
            musicLibrarySnapshots = try await musicLibraryFetcher.snapshots(for: candidates)
        } catch is CancellationError {
            return Result()
        } catch {
            // Library metadata is supporting evidence only. A failed or
            // unavailable request must not block the existing local proofs.
            TrackMetadataDiagnostics.log(
                "MusicKit playback history query failed: \(error.localizedDescription)"
            )
            musicLibrarySnapshots = [:]
        }
        guard !Task.isCancelled else { return Result() }

        var outcome = PlaybackReconciliationPolicy.reconcile(
            waypoint: waypoint,
            observation: observation,
            orderedTracks: orderedTracks,
            playthroughThresholdPercentage: threshold,
            musicLibrarySnapshots: musicLibrarySnapshots
        )

        // The live monitor may already have counted the current play.
        if let pointProven = outcome.pointProvenLocalTrackID,
           playbackController.activeSessionHasEvaluated(localTrackID: pointProven) {
            outcome.pointProvenLocalTrackID = nil
        }

        var counted: [String] = []
        if let settings {
            counted = countPlaythroughs(
                outcome: outcome,
                observation: observation,
                waypoint: waypoint,
                orderedTracks: orderedTracks,
                settings: settings,
                context: context
            )
        }

        if let pointProven = outcome.pointProvenLocalTrackID, counted.contains(pointProven) {
            playbackController.markActiveSessionPlaythroughCounted(localTrackID: pointProven)
        }

        saveWaypoint(
            observation: observation,
            previousWaypoint: waypoint,
            pointProvenAndCounted: outcome.pointProvenLocalTrackID.map(counted.contains) == true,
            musicLibrarySnapshot: musicLibrarySnapshots[observation.localTrackID],
            resolvedMusicLibraryLocalTrackIDs: Set(outcome.musicLibraryProvenLocalTrackIDs),
            countedLocalTrackIDs: Set(counted),
            playbackController: playbackController
        )

        if !counted.isEmpty {
            TrackMetadataDiagnostics.log(
                "reconciled suspended playthroughs count=\(counted.count) tracks=\(counted.joined(separator: ",")) observed=\(observation.localTrackID)@\(String(format: "%.1f", observation.positionSeconds))"
            )
        }

        return Result(
            countedLocalTrackIDs: counted,
            nextWakeTarget: nextWakeTarget(
                observation: observation,
                orderedTracks: orderedTracks,
                playthroughThresholdPercentage: threshold
            )
        )
    }

    private static func musicLibraryCandidates(
        localTrackIDs: Set<String>,
        context: ModelContext
    ) -> [MusicLibraryPlaybackCandidate] {
        let ids = localTrackIDs.compactMap(UUID.init(uuidString:))
        let tracks = (try? TrackRecordRepository.tracks(ids: ids, in: context)) ?? []
        return tracks.compactMap { track in
            let musicItemIDs = PlaybackQueueBuilder.musicItemIDs(for: track)
            guard !musicItemIDs.isEmpty else { return nil }
            return MusicLibraryPlaybackCandidate(
                localTrackID: track.id.uuidString,
                musicItemIDs: musicItemIDs
            )
        }
    }

    private static func orderedTracks(
        playlistID: String,
        playerID: String,
        scope: PlaylistPlaybackScope,
        context: ModelContext
    ) -> [PlaybackReconciliationPolicy.OrderedTrack] {
        let state = PlaybackOrderStore.state(
            playerID: playerID,
            musicPlaylistID: scope.playbackOrderPlaylistID(for: playlistID)
        )
        guard !state.orderedTrackIDs.isEmpty else { return [] }

        let trackUUIDs = state.orderedTrackIDs.compactMap(UUID.init(uuidString:))
        let durationsByID = ((try? TrackRecordRepository.tracks(ids: trackUUIDs, in: context)) ?? [])
            .firstValueDictionary(keyedBy: \.id)
            .reduce(into: [String: Double]()) { result, entry in
                if let duration = entry.value.durationSeconds {
                    result[entry.key.uuidString] = duration
                }
            }
        return state.orderedTrackIDs.map {
            PlaybackReconciliationPolicy.OrderedTrack(
                localTrackID: $0,
                durationSeconds: durationsByID[$0]
            )
        }
    }

    private static func countPlaythroughs(
        outcome: PlaybackReconciliationPolicy.Outcome,
        observation: PlaybackReconciliationPolicy.Observation,
        waypoint: PlaybackWaypoint?,
        orderedTracks: [PlaybackReconciliationPolicy.OrderedTrack],
        settings: OverplaySettings,
        context: ModelContext
    ) -> [String] {
        guard let playlist = try? PlaylistRepository.playlist(
            musicPlaylistID: observation.playlistID,
            in: context
        ) else { return [] }
        guard let items = try? PlaylistItemRepository.items(forPlaylistID: playlist.id, in: context) else {
            return []
        }

        let itemsByLocalTrackID = items.firstValueDictionary(keyedBy: \.trackID)
            .reduce(into: [String: PlaylistItemRecord]()) { result, entry in
                result[entry.key.uuidString] = entry.value
            }
        let durationsByLocalTrackID = orderedTracks
            .reduce(into: [String: Double]()) { result, track in
                result[track.localTrackID] = track.durationSeconds
            }

        var counted: [String] = []
        for localTrackID in outcome.continuityProvenLocalTrackIDs {
            guard let item = itemsByLocalTrackID[localTrackID],
                  item.evictedAt == nil,
                  !alreadyCreditedDuringSpan(item: item, waypoint: waypoint) else {
                continue
            }

            // A continuity-proven track played to its end.
            let duration = durationsByLocalTrackID[localTrackID]
            EvictionEngine.countPlaythrough(
                item,
                playlist: playlist,
                session: syntheticSession(
                    localTrackID: localTrackID,
                    positionSeconds: duration ?? 0,
                    durationSeconds: duration,
                    observedAt: observation.observedAt
                ),
                settings: settings,
                source: .reconciled,
                reconciliationMechanism: .wallClockContinuity,
                message: "Played through while Overplay was suspended",
                context: context
            )
            counted.append(localTrackID)
        }

        for musicLibraryProven in outcome.musicLibraryProvenLocalTrackIDs {
            guard !counted.contains(musicLibraryProven),
                  let item = itemsByLocalTrackID[musicLibraryProven],
                  item.evictedAt == nil,
                  !alreadyCreditedSinceMusicLibraryBaseline(
                    item: item,
                    localTrackID: musicLibraryProven,
                    waypoint: waypoint
                  ) else {
                continue
            }
            let duration = durationsByLocalTrackID[musicLibraryProven]
            EvictionEngine.countPlaythrough(
                item,
                playlist: playlist,
                session: syntheticSession(
                    localTrackID: musicLibraryProven,
                    positionSeconds: duration ?? 0,
                    durationSeconds: duration,
                    observedAt: observation.observedAt
                ),
                settings: settings,
                source: .reconciled,
                reconciliationMechanism: .musicKitPlayCount,
                message: "Apple Music library play count advanced while Overplay was suspended",
                context: context
            )
            counted.append(musicLibraryProven)
        }

        if let pointProven = outcome.pointProvenLocalTrackID,
           !counted.contains(pointProven),
           let item = itemsByLocalTrackID[pointProven],
           item.evictedAt == nil,
           !alreadyCreditedThisPlayInstance(item: item, observation: observation) {
            EvictionEngine.countPlaythrough(
                item,
                playlist: playlist,
                session: syntheticSession(
                    localTrackID: pointProven,
                    positionSeconds: observation.positionSeconds,
                    durationSeconds: observation.durationSeconds,
                    observedAt: observation.observedAt
                ),
                settings: settings,
                source: .reconciled,
                reconciliationMechanism: .pointObservation,
                message: "Reached \(Int(settings.playthroughThresholdPercentage))% while Overplay was suspended",
                context: context
            )
            counted.append(pointProven)
        }

        if !counted.isEmpty {
            try? context.save()
        }
        return counted
    }

    /// An item credited after the waypoint was recorded was counted inside
    /// this span already (by the live monitor before suspension, or by an
    /// earlier wake) — never credit the same span twice.
    private static func alreadyCreditedDuringSpan(item: PlaylistItemRecord, waypoint: PlaybackWaypoint?) -> Bool {
        guard let waypoint, let lastPlayedAt = item.lastPlayedAt else { return false }
        return lastPlayedAt > waypoint.recordedAt
    }

    private static func alreadyCreditedSinceMusicLibraryBaseline(
        item: PlaylistItemRecord,
        localTrackID: String,
        waypoint: PlaybackWaypoint?
    ) -> Bool {
        guard let lastPlayedAt = item.lastPlayedAt,
              let baselineDate = waypoint?.allMusicLibraryBaselines
                .filter({ $0.localTrackID == localTrackID })
                .map(\.recordedAt)
                .min() else {
            return false
        }
        return lastPlayedAt >= baselineDate
    }

    /// Point-proof guard for process-death gaps the in-memory session can't
    /// cover: if the item was credited after this play instance started
    /// (estimated from the observed position), it was already counted.
    private static func alreadyCreditedThisPlayInstance(
        item: PlaylistItemRecord,
        observation: PlaybackReconciliationPolicy.Observation
    ) -> Bool {
        guard let lastPlayedAt = item.lastPlayedAt else { return false }
        let estimatedInstanceStart = observation.observedAt
            .addingTimeInterval(-(observation.positionSeconds + PlaybackReconciliationPolicy.baseToleranceSeconds))
        return lastPlayedAt >= estimatedInstanceStart
    }

    /// The session exists only to carry position/duration into the history
    /// event; it is never evaluated.
    private static func syntheticSession(
        localTrackID: String,
        positionSeconds: Double,
        durationSeconds: Double?,
        observedAt: Date
    ) -> TrackPlaySession {
        TrackPlaySession(
            trackID: localTrackID,
            localTrackID: localTrackID,
            sessionStartDate: observedAt,
            lastObservedPlaybackTime: positionSeconds,
            durationSeconds: durationSeconds,
            hasEvaluated: true
        )
    }

    private static func saveWaypoint(
        observation: PlaybackReconciliationPolicy.Observation,
        previousWaypoint: PlaybackWaypoint?,
        pointProvenAndCounted: Bool,
        musicLibrarySnapshot: MusicLibraryPlaybackSnapshot?,
        resolvedMusicLibraryLocalTrackIDs: Set<String>,
        countedLocalTrackIDs: Set<String>,
        playbackController: PlaybackController
    ) {
        // Carry the point-proof ledger forward while the same play instance
        // continues, so repeated wakes inside one track never double count —
        // including across a process death.
        let countedLocalTrackID: String? = {
            if pointProvenAndCounted {
                return observation.localTrackID
            }
            if playbackController.activeSessionHasEvaluated(localTrackID: observation.localTrackID) {
                return observation.localTrackID
            }
            if let previousWaypoint,
               previousWaypoint.localTrackID == observation.localTrackID,
               previousWaypoint.countedLocalTrackID == observation.localTrackID,
               observation.positionSeconds >= previousWaypoint.positionSeconds {
                return observation.localTrackID
            }
            return nil
        }()

        // Async MusicKit work can overlap a scene transition. Never allow an
        // older observation that finishes later to move the waypoint back.
        if let storedWaypoint = PlaybackWaypointStore.load(),
           storedWaypoint.recordedAt > observation.observedAt {
            return
        }

        let persistedMusicLibrarySnapshot = musicLibrarySnapshot
            ?? previousWaypoint.flatMap { waypoint in
                waypoint.localTrackID == observation.localTrackID
                    ? waypoint.musicLibrarySnapshot
                    : nil
            }
        var pendingMusicLibraryBaselines = previousWaypoint?.pendingMusicLibraryBaselines ?? []
        if let previousWaypoint,
           previousWaypoint.localTrackID != observation.localTrackID,
           let previousSnapshot = previousWaypoint.musicLibrarySnapshot {
            pendingMusicLibraryBaselines.append(MusicLibraryPlaybackBaseline(
                playlistID: previousWaypoint.playlistID,
                localTrackID: previousWaypoint.localTrackID,
                recordedAt: previousWaypoint.recordedAt,
                snapshot: previousSnapshot
            ))
        }
        let resolvedLocalTrackIDs = resolvedMusicLibraryLocalTrackIDs.union(countedLocalTrackIDs)
        let pendingExpiry = observation.observedAt.addingTimeInterval(-24 * 60 * 60)
        var retainedLocalTrackIDs = Set<String>()
        pendingMusicLibraryBaselines = pendingMusicLibraryBaselines.filter { baseline in
            baseline.playlistID == observation.playlistID
                && baseline.recordedAt >= pendingExpiry
                && !resolvedLocalTrackIDs.contains(baseline.localTrackID)
                && retainedLocalTrackIDs.insert(baseline.localTrackID).inserted
        }
        pendingMusicLibraryBaselines = Array(
            pendingMusicLibraryBaselines.suffix(maxPendingMusicLibraryBaselines)
        )
        PlaybackWaypointStore.save(
            PlaybackWaypoint(
                playlistID: observation.playlistID,
                localTrackID: observation.localTrackID,
                positionSeconds: observation.positionSeconds,
                durationSeconds: observation.durationSeconds,
                recordedAt: observation.observedAt,
                countedLocalTrackID: countedLocalTrackID,
                musicLibrarySnapshot: persistedMusicLibrarySnapshot,
                pendingMusicLibraryBaselines: pendingMusicLibraryBaselines.isEmpty
                    ? nil
                    : pendingMusicLibraryBaselines
            ),
            flushImmediately: true
        )
    }

    private static func nextWakeTarget(
        observation: PlaybackReconciliationPolicy.Observation,
        orderedTracks: [PlaybackReconciliationPolicy.OrderedTrack],
        playthroughThresholdPercentage: Double
    ) -> Date? {
        let nextDuration: Double? = orderedTracks
            .firstIndex { $0.localTrackID == observation.localTrackID }
            .flatMap { index in
                let nextIndex = index + 1
                guard orderedTracks.indices.contains(nextIndex) else { return nil }
                return orderedTracks[nextIndex].durationSeconds
            }

        return PlaybackReconciliationPolicy.nextWakeTarget(
            positionSeconds: observation.positionSeconds,
            durationSeconds: observation.durationSeconds,
            nextDurationSeconds: nextDuration,
            playthroughThresholdPercentage: playthroughThresholdPercentage,
            now: observation.observedAt
        )
    }
}
