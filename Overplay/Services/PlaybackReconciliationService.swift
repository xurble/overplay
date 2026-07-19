import Foundation
import SwiftData

/// Reconciles playback that happened while Overplay was suspended and picks
/// the next background wake target. Runs on every wake: a background
/// refresh grant, scene foregrounding, and just before suspension (which
/// records the exact baseline waypoint).
@MainActor
enum PlaybackReconciliationService {
    struct Result {
        var countedLocalTrackIDs: [String] = []
        var nextWakeTarget: Date?
    }

    @discardableResult
    static func reconcileAndCaptureWaypoint(
        playbackController: PlaybackController,
        context: ModelContext
    ) -> Result {
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

        var outcome = PlaybackReconciliationPolicy.reconcile(
            waypoint: waypoint,
            observation: observation,
            orderedTracks: orderedTracks,
            playthroughThresholdPercentage: threshold
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
                message: "Played through while Overplay was suspended",
                context: context
            )
            counted.append(localTrackID)
        }

        if let pointProven = outcome.pointProvenLocalTrackID,
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

        PlaybackWaypointStore.save(
            PlaybackWaypoint(
                playlistID: observation.playlistID,
                localTrackID: observation.localTrackID,
                positionSeconds: observation.positionSeconds,
                durationSeconds: observation.durationSeconds,
                recordedAt: observation.observedAt,
                countedLocalTrackID: countedLocalTrackID
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
