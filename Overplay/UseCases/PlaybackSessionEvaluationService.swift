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
        elapsedSeconds: Double,
        durationSeconds: Double?
    ) -> TrackPlaySession? {
        guard let trackID else { return nil }

        return PlaybackSessionSupport.makeSession(
            trackID: trackID,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds
        )
    }

    static func updateObservedProgress(
        _ session: TrackPlaySession,
        elapsedSeconds: Double,
        durationSeconds: Double?
    ) -> TrackPlaySession {
        var session = session
        session.lastObservedPlaybackTime = elapsedSeconds
        session.durationSeconds = durationSeconds
        return session
    }

    static func markEvaluatedWithoutSkip(
        activeSession: TrackPlaySession?,
        currentTrackID: String?,
        elapsedSeconds: Double,
        durationSeconds: Double?
    ) -> TrackPlaySession? {
        guard var session = activeSession ?? bootstrapSession(
            trackID: currentTrackID,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds
        ) else {
            return nil
        }

        session.hasEvaluated = true
        return session
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
        fallbackLocalTrackID: String? = nil
    ) throws -> EvaluationOutcome? {
        guard var session = activeSession ?? bootstrapSession(
            trackID: currentTrackID,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds
        ) else {
            return nil
        }

        session = updateObservedProgress(
            session,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds
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
            return EvaluationOutcome(
                session: session,
                playlist: playlist,
                item: nil,
                evictedDuringEvaluation: false,
                shouldSyncPlaybackMetadata: false
            )
        }

        let wasEvicted = item.evictedAt != nil
        EvictionEngine.evaluateSkip(
            item: item,
            playlist: playlist,
            session: session,
            transitionWasNaturalCompletion: naturalCompletion,
            settings: settings,
            context: context
        )
        session.hasEvaluated = true
        try context.save()

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
        if let item = try PlaybackSessionSupport.resolvePlaylistItem(
            forMusicItemID: session.trackID,
            currentPlaylistItem: currentPlaylistItem,
            playlist: playlist,
            in: context
        ) {
            return item
        }

        if let fallbackLocalTrackID,
           let trackID = UUID(uuidString: fallbackLocalTrackID),
           let item = try PlaylistItemRepository.item(
               playlistID: playlist.id,
               trackID: trackID,
               in: context
           ) {
            return item
        }

        if let currentPlaylistItem,
           currentPlaylistItem.playlistID == playlist.id {
            return currentPlaylistItem
        }

        return nil
    }
}
