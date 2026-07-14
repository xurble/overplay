import Foundation
import SwiftData

enum PlaybackSessionEvaluationService {
    struct EvaluationOutcome {
        var session: TrackPlaySession
        var playlist: PlaylistRecord?
        var item: PlaylistItemRecord?
        var evictedDuringEvaluation: Bool
        var shouldSyncPlaybackMetadata: Bool
    }

    static func bootstrapSession(
        trackID: String?,
        localTrackID: String? = nil,
        elapsedSeconds: Double,
        durationSeconds: Double?
    ) -> TrackPlaySession? {
        guard let trackID else { return nil }

        return PlaybackSessionSupport.makeSession(
            trackID: trackID,
            localTrackID: localTrackID,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds
        )
    }

    /// How old the latest playback observation may be before a transition
    /// can no longer be judged. Polling runs every second while the app is
    /// active, so anything beyond a few missed polls means the app was
    /// suspended while playback continued out-of-process.
    static let observationStalenessThresholdSeconds: Double = 5

    /// A track that ends between polls leaves its last observation just
    /// short of the duration. Within this window the transition is treated
    /// as a natural completion rather than a user skip.
    static let naturalCompletionToleranceSeconds: Double = 3

    static func inferredNaturalCompletion(session: TrackPlaySession) -> Bool {
        guard let durationSeconds = session.durationSeconds, durationSeconds > 0 else {
            return false
        }
        return durationSeconds - session.lastObservedPlaybackTime <= naturalCompletionToleranceSeconds
    }

    /// The largest position delta between observations that still counts as
    /// continuous listening. Polling runs every second; anything larger is a
    /// seek, a stale jump, or missed polls, none of which the user listened
    /// through.
    static let maximumObservedListeningDeltaSeconds: Double = 1.5

    static func updateObservedProgress(
        _ session: TrackPlaySession,
        elapsedSeconds: Double,
        durationSeconds: Double?,
        observedAt: Date = .now
    ) -> TrackPlaySession {
        var session = session
        let positionDelta = elapsedSeconds - session.lastObservedPlaybackTime
        if positionDelta > 0, positionDelta <= maximumObservedListeningDeltaSeconds {
            session.listenedSeconds += positionDelta
        }
        session.lastObservedPlaybackTime = elapsedSeconds
        session.durationSeconds = durationSeconds
        session.lastObservedAt = observedAt
        return session
    }

    static func markEvaluatedWithoutSkip(
        activeSession: TrackPlaySession?,
        currentTrackID: String?,
        localTrackID: String? = nil,
        elapsedSeconds: Double,
        durationSeconds: Double?
    ) -> TrackPlaySession? {
        guard var session = activeSession ?? bootstrapSession(
            trackID: currentTrackID,
            localTrackID: localTrackID,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds
        ) else {
            return nil
        }

        session.hasEvaluated = true
        return session
    }

    static func skipWouldCount(
        elapsedSeconds: Double,
        durationSeconds: Double?,
        skipThresholdPercentage: Double,
        minimumSkipListeningSeconds: Double
    ) -> Bool {
        elapsedSeconds >= minimumSkipListeningSeconds
            && progressPercentage(elapsedSeconds: elapsedSeconds, durationSeconds: durationSeconds) < skipThresholdPercentage
    }

    static func playthroughThresholdReached(session: TrackPlaySession, settings: OverplaySettings) -> Bool {
        progressPercentage(
            elapsedSeconds: session.lastObservedPlaybackTime,
            durationSeconds: session.durationSeconds
        ) >= settings.playthroughThresholdPercentage
    }

    static func progressPercentage(elapsedSeconds: Double, durationSeconds: Double?) -> Double {
        guard let durationSeconds, durationSeconds > 0 else { return 0 }
        return min(max((elapsedSeconds / durationSeconds) * 100, 0), 100)
    }

    static func evaluateActiveSession(
        activeSession: TrackPlaySession?,
        currentTrackID: String?,
        elapsedSeconds: Double,
        durationSeconds: Double?,
        currentPlaylistItem: PlaylistItemRecord?,
        playlist: PlaylistRecord?,
        settings: OverplaySettings,
        naturalCompletion: Bool,
        context: ModelContext,
        fallbackLocalTrackID: String? = nil,
        now: Date = .now
    ) throws -> EvaluationOutcome? {
        guard var session = activeSession ?? bootstrapSession(
            trackID: currentTrackID,
            localTrackID: fallbackLocalTrackID ?? currentPlaylistItem?.trackID.uuidString,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds
        ) else {
            return nil
        }

        guard !session.hasEvaluated else {
            return EvaluationOutcome(
                session: session,
                playlist: playlist,
                item: nil,
                evictedDuringEvaluation: false,
                shouldSyncPlaybackMetadata: false
            )
        }

        // Judged before the progress update below, which stamps a fresh
        // observation date onto the copy being evaluated.
        let observationIsStale = now.timeIntervalSince(session.lastObservedAt) > observationStalenessThresholdSeconds
        session = updateObservedProgress(
            session,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds,
            observedAt: observationIsStale ? session.lastObservedAt : now
        )

        guard let playlist,
              let item = try resolvedPlaylistItem(
                  for: session,
                  currentPlaylistItem: currentPlaylistItem,
                  fallbackLocalTrackID: fallbackLocalTrackID,
                  playlist: playlist,
                  context: context
              ) else {
            session.hasEvaluated = true
            TrackMetadataDiagnostics.log(
                "session evaluation could not resolve playlist item trackID=\(session.trackID) localTrackID=\(session.localTrackID ?? "nil") fallbackLocalTrackID=\(fallbackLocalTrackID ?? "nil") playlist=\(TrackMetadataDiagnostics.describe(playlist)) currentItem=\(TrackMetadataDiagnostics.describe(currentPlaylistItem))"
            )
            return EvaluationOutcome(
                session: session,
                playlist: playlist,
                item: nil,
                evictedDuringEvaluation: false,
                shouldSyncPlaybackMetadata: false
            )
        }

        let wasEvicted = item.evictedAt != nil
        let canCountPlaythrough = item.evictedAt == nil
        // MusicKit advances tracks itself at natural completion, so most
        // completions arrive here as plain track changes. An observation
        // within a poll gap of the duration is a completion, not a skip.
        let completedNaturally = naturalCompletion || inferredNaturalCompletion(session: session)
        if canCountPlaythrough && (completedNaturally || playthroughThresholdReached(session: session, settings: settings)) {
            EvictionEngine.countPlaythrough(
                item,
                playlist: playlist,
                session: session,
                settings: settings,
                context: context
            )
        } else {
            EvictionEngine.evaluateSkip(
                item: item,
                playlist: playlist,
                session: session,
                transitionWasNaturalCompletion: completedNaturally,
                observationIsStale: observationIsStale,
                settings: settings,
                context: context
            )
        }
        session.hasEvaluated = true
        try context.save()
        TrackMetadataDiagnostics.log(
            "session evaluation saved naturalCompletion=\(naturalCompletion) trackID=\(session.trackID) localTrackID=\(session.localTrackID ?? "nil") progress=\(session.progressPercentage.map { String(format: "%.1f", $0) } ?? "nil") playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item))"
        )

        return EvaluationOutcome(
            session: session,
            playlist: playlist,
            item: item,
            evictedDuringEvaluation: !wasEvicted && item.evictedAt != nil,
            shouldSyncPlaybackMetadata: true
        )
    }

    static func evaluatePlaythroughIfNeeded(
        session: TrackPlaySession?,
        currentPlaylistItem: PlaylistItemRecord?,
        playlist: PlaylistRecord?,
        settings: OverplaySettings,
        context: ModelContext,
        fallbackLocalTrackID: String? = nil
    ) throws -> EvaluationOutcome? {
        guard var session, !session.hasEvaluated else { return nil }
        guard let progress = session.progressPercentage else { return nil }
        guard progress >= settings.playthroughThresholdPercentage else { return nil }
        guard let playlist,
              let item = try resolvedPlaylistItem(
                  for: session,
                  currentPlaylistItem: currentPlaylistItem,
                  fallbackLocalTrackID: fallbackLocalTrackID,
                  playlist: playlist,
                  context: context
              ),
              item.evictedAt == nil else {
            return nil
        }

        EvictionEngine.countPlaythrough(
            item,
            playlist: playlist,
            session: session,
            settings: settings,
            context: context
        )
        session.hasEvaluated = true
        try context.save()
        TrackMetadataDiagnostics.log(
            "playthrough evaluation saved trackID=\(session.trackID) localTrackID=\(session.localTrackID ?? "nil") progress=\(session.progressPercentage.map { String(format: "%.1f", $0) } ?? "nil") playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item))"
        )

        return EvaluationOutcome(
            session: session,
            playlist: playlist,
            item: item,
            evictedDuringEvaluation: false,
            shouldSyncPlaybackMetadata: true
        )
    }

    private static func resolvedPlaylistItem(
        for session: TrackPlaySession,
        currentPlaylistItem: PlaylistItemRecord?,
        fallbackLocalTrackID: String?,
        playlist: PlaylistRecord,
        context: ModelContext
    ) throws -> PlaylistItemRecord? {
        if let localTrackID = session.localTrackID ?? fallbackLocalTrackID,
           let trackID = UUID(uuidString: localTrackID),
           let item = try PlaylistItemRepository.item(
               playlistID: playlist.id,
               trackID: trackID,
               in: context
           ) {
            return item
        }

        if let item = try PlaybackSessionSupport.resolvePlaylistItem(
            forMusicItemID: session.trackID,
            currentPlaylistItem: currentPlaylistItem,
            playlist: playlist,
            in: context
        ) {
            return item
        }

        return nil
    }
}
