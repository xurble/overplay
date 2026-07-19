import Foundation

/// Decides which playthroughs can be PROVEN for playback that happened while
/// Overplay was suspended, and where to aim the next background wake.
///
/// Skips are never reconstructed — unwitnessed transitions must never count
/// (the same rule the live evaluation enforces). Playthroughs are recovered
/// under three proof rules; anything ambiguous counts nothing:
///
/// - POINT-PROOF: an observation showing the current track at or past the
///   playthrough threshold counts it outright. Playthroughs are
///   position-based in the live engine too (seeking past the threshold
///   counts), so a single trusted position observation is sufficient proof,
///   immune to pauses or stalls earlier in the track.
/// - CONTINUITY-PROOF: between two observations, if the elapsed wall time
///   accounts for the durations of every traversed track, playback was
///   provably continuous and each completed track counts. Any mismatch —
///   pause, skip, stall, seek, unknown duration, changed playlist — fails
///   the equation and nothing in the span is counted.
/// - MUSIC-LIBRARY-PROOF: Apple Music's play count for the waypoint track
///   increased and its last-played date also advanced into the observed
///   interval. Missing or stale library data is neutral, never negative.
enum PlaybackReconciliationPolicy {
    /// Wall-clock slack allowed per track boundary crossed (gap between
    /// tracks, poll jitter at the edges).
    static let boundaryToleranceSeconds = 3.0
    /// Base wall-clock slack for a continuity span.
    static let baseToleranceSeconds = 5.0
    /// BGTaskScheduler treats sub-minute leads as effectively immediate;
    /// never request a wake sooner than this.
    static let minimumWakeLeadSeconds = 60.0
    /// Aim slightly past the threshold crossing so an on-time grant lands
    /// inside the proof window rather than on its edge.
    static let wakeMarginSeconds = 5.0

    struct Observation: Equatable {
        var playlistID: String
        var localTrackID: String
        var positionSeconds: Double
        var durationSeconds: Double?
        var observedAt: Date
    }

    struct OrderedTrack: Equatable {
        var localTrackID: String
        var durationSeconds: Double?
    }

    struct Outcome: Equatable {
        /// The observed current track, proven by position alone.
        var pointProvenLocalTrackID: String?
        /// Tracks proven completed by wall-clock continuity since the
        /// previous waypoint, in playback order.
        var continuityProvenLocalTrackIDs: [String] = []
        /// Waypoint tracks corroborated by Apple Music's library play count
        /// and last-played date, including delayed results from older wakes.
        var musicLibraryProvenLocalTrackIDs: [String] = []
    }

    static func reconcile(
        waypoint: PlaybackWaypoint?,
        observation: Observation,
        orderedTracks: [OrderedTrack],
        playthroughThresholdPercentage: Double,
        musicLibrarySnapshots: [String: MusicLibraryPlaybackSnapshot] = [:]
    ) -> Outcome {
        Outcome(
            pointProvenLocalTrackID: pointProvenLocalTrackID(
                waypoint: waypoint,
                observation: observation,
                playthroughThresholdPercentage: playthroughThresholdPercentage
            ),
            continuityProvenLocalTrackIDs: continuityProvenLocalTrackIDs(
                waypoint: waypoint,
                observation: observation,
                orderedTracks: orderedTracks
            ),
            musicLibraryProvenLocalTrackIDs: musicLibraryProvenLocalTrackIDs(
                waypoint: waypoint,
                observation: observation,
                latestSnapshots: musicLibrarySnapshots
            )
        )
    }

    private static func musicLibraryProvenLocalTrackIDs(
        waypoint: PlaybackWaypoint?,
        observation: Observation,
        latestSnapshots: [String: MusicLibraryPlaybackSnapshot]
    ) -> [String] {
        guard let waypoint else { return [] }
        var provenLocalTrackIDs: [String] = []
        for baseline in waypoint.allMusicLibraryBaselines {
            guard baseline.playlistID == observation.playlistID,
                  waypoint.countedLocalTrackID != baseline.localTrackID,
                  !provenLocalTrackIDs.contains(baseline.localTrackID),
                  let latest = latestSnapshots[baseline.localTrackID],
                  baseline.snapshot.musicItemID == latest.musicItemID,
                  let baselinePlayCount = baseline.snapshot.playCount,
                  let latestPlayCount = latest.playCount,
                  latestPlayCount > baselinePlayCount,
                  let latestLastPlayedDate = latest.lastPlayedDate else {
                continue
            }

            if let baselineLastPlayedDate = baseline.snapshot.lastPlayedDate,
               latestLastPlayedDate <= baselineLastPlayedDate {
                continue
            }

            let intervalStart = baseline.recordedAt.addingTimeInterval(-baseToleranceSeconds)
            let intervalEnd = observation.observedAt.addingTimeInterval(baseToleranceSeconds)
            guard latestLastPlayedDate >= intervalStart,
                  latestLastPlayedDate <= intervalEnd else {
                // A delayed counter that refers to playback before this
                // baseline must not be attributed to the suspended interval.
                continue
            }
            provenLocalTrackIDs.append(baseline.localTrackID)
        }
        return provenLocalTrackIDs
    }

    private static func pointProvenLocalTrackID(
        waypoint: PlaybackWaypoint?,
        observation: Observation,
        playthroughThresholdPercentage: Double
    ) -> String? {
        guard let durationSeconds = observation.durationSeconds, durationSeconds > 0 else {
            return nil
        }
        guard (observation.positionSeconds / durationSeconds) * 100 >= playthroughThresholdPercentage else {
            return nil
        }

        // Same play instance already counted: the waypoint observed this
        // track earlier, credited it, and the position has only moved
        // forward since. A position reset means a fresh play of the track.
        if let waypoint,
           waypoint.localTrackID == observation.localTrackID,
           waypoint.countedLocalTrackID == observation.localTrackID,
           observation.positionSeconds >= waypoint.positionSeconds {
            return nil
        }

        return observation.localTrackID
    }

    private static func continuityProvenLocalTrackIDs(
        waypoint: PlaybackWaypoint?,
        observation: Observation,
        orderedTracks: [OrderedTrack]
    ) -> [String] {
        guard let waypoint,
              waypoint.playlistID == observation.playlistID,
              waypoint.localTrackID != observation.localTrackID else {
            return []
        }
        guard let waypointIndex = orderedTracks.firstIndex(where: { $0.localTrackID == waypoint.localTrackID }),
              let observationIndex = orderedTracks.firstIndex(where: { $0.localTrackID == observation.localTrackID }),
              waypointIndex < observationIndex else {
            // The observed track precedes the waypoint (queue restarted or
            // reshuffled) — the traversal is unknowable. Count nothing.
            return []
        }

        let traversed = Array(orderedTracks[waypointIndex..<observationIndex])
        let durations = traversed.compactMap(\.durationSeconds)
        guard durations.count == traversed.count,
              let waypointDuration = durations.first, waypointDuration > 0,
              !durations.contains(where: { $0 <= 0 }) else {
            return []
        }

        let intermediateSeconds = durations.dropFirst().reduce(0.0, +)
        let expectedSeconds = (waypointDuration - waypoint.positionSeconds)
            + intermediateSeconds
            + observation.positionSeconds
        let actualSeconds = observation.observedAt.timeIntervalSince(waypoint.recordedAt)
        let boundariesCrossed = observationIndex - waypointIndex
        let tolerance = baseToleranceSeconds + boundaryToleranceSeconds * Double(boundariesCrossed)
        guard abs(actualSeconds - expectedSeconds) <= tolerance else {
            return []
        }

        // Every traversed track completed. Exclude the waypoint track if its
        // play instance was already point-proven at an earlier wake.
        return traversed
            .map(\.localTrackID)
            .filter { $0 != waypoint.countedLocalTrackID }
    }

    /// The next `earliestBeginDate` to request. Aims at the playthrough
    /// threshold crossing of the current track — the earliest instant a
    /// single snapshot proves the playthrough by itself. BGAppRefresh allows
    /// one pending request and grants are only ever late, so aiming at the
    /// start of the [threshold, end] window maximises the chance of landing
    /// inside it; a late grant lands early in the next track, which still
    /// pins the boundary tightly for continuity proof. Past the crossing,
    /// aim at the next track's crossing instead.
    static func nextWakeTarget(
        positionSeconds: Double,
        durationSeconds: Double?,
        nextDurationSeconds: Double?,
        playthroughThresholdPercentage: Double,
        now: Date
    ) -> Date? {
        guard let durationSeconds, durationSeconds > 0 else {
            return nil
        }

        let crossing = durationSeconds * playthroughThresholdPercentage / 100
        let lead: Double
        if positionSeconds < crossing {
            lead = (crossing - positionSeconds) + wakeMarginSeconds
        } else if let nextDurationSeconds, nextDurationSeconds > 0 {
            lead = (durationSeconds - positionSeconds)
                + nextDurationSeconds * playthroughThresholdPercentage / 100
                + wakeMarginSeconds
        } else {
            // Next duration unknown: aim just past the boundary so the wake
            // at least pins the transition.
            lead = (durationSeconds - positionSeconds) + wakeMarginSeconds
        }

        return now.addingTimeInterval(max(lead, minimumWakeLeadSeconds))
    }
}
