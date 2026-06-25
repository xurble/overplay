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

    static func skipForwardIntent(
        session: TrackPlaySession?,
        item: PlaylistItemRecord?,
        playlist: PlaylistRecord?,
        settings: OverplaySettings
    ) -> PlaybackSkipForwardIntent {
        guard let session,
              !session.hasEvaluated,
              let item,
              let playlist,
              item.evictedAt == nil else {
            return .standard
        }

        if playthroughWouldResetSkipCount(session: session, item: item, settings: settings) {
            return .skipCountReset
        }

        guard !item.protected,
              skipWouldCount(session: session, settings: settings) else {
            return .standard
        }

        let wouldReachEvictionThreshold = item.skipCount + 1 >= settings.evictAfterSkips
        let shouldAutoEvict = playlist.role == .oneTruePlaylist
            || settings.triageAutoEvictsOnSkipCount
        return wouldReachEvictionThreshold && shouldAutoEvict ? .eviction : .countedSkip
    }

    static func skipWouldCount(session: TrackPlaySession, settings: OverplaySettings) -> Bool {
        skipWouldCount(
            elapsedSeconds: session.lastObservedPlaybackTime,
            durationSeconds: session.durationSeconds,
            skipThresholdPercentage: settings.skipThresholdPercentage,
            minimumSkipListeningSeconds: settings.minimumSkipListeningSeconds
        )
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

    static func playthroughWouldResetSkipCount(
        session: TrackPlaySession,
        item: PlaylistItemRecord,
        settings: OverplaySettings
    ) -> Bool {
        settings.playthroughResetsSkipCount
            && item.skipCount > 0
            && playthroughThresholdReached(session: session, settings: settings)
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
        fallbackLocalTrackID: String? = nil
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
        let canCountPlaythrough = item.evictedAt == nil && !item.protected
        if canCountPlaythrough && (naturalCompletion || playthroughThresholdReached(session: session, settings: settings)) {
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
                transitionWasNaturalCompletion: naturalCompletion,
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

        if let currentPlaylistItem,
           currentPlaylistItem.playlistID == playlist.id {
            return currentPlaylistItem
        }

        return nil
    }
}
