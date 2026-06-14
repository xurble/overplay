import Foundation
import SwiftData

struct TrackPlaySession: Equatable {
    var trackID: String
    var sessionStartDate: Date
    var lastObservedPlaybackTime: Double
    var durationSeconds: Double?
    var hasEvaluated: Bool

    var progressPercentage: Double? {
        guard let durationSeconds, durationSeconds > 0 else {
            return nil
        }
        return min((lastObservedPlaybackTime / durationSeconds) * 100, 100)
    }
}

enum EvictionEngine {
    static func evaluateSkip(
        item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        session: TrackPlaySession,
        transitionWasNaturalCompletion: Bool,
        settings: OverplaySettings,
        context: ModelContext
    ) {
        guard !session.hasEvaluated else { return }
        guard item.evictedAt == nil else {
            logHistory(
                item: item,
                playlist: playlist,
                eventType: .skipIgnored,
                source: .playback,
                session: session,
                message: "Already evicted",
                context: context
            )
            return
        }
        guard !item.protected else {
            logHistory(
                item: item,
                playlist: playlist,
                eventType: .skipIgnored,
                source: .playback,
                session: session,
                message: "Protected",
                context: context
            )
            return
        }

        if transitionWasNaturalCompletion {
            countPlaythrough(item, playlist: playlist, session: session, settings: settings, context: context)
            return
        }

        let progress = session.progressPercentage ?? 0
        let listenedLongEnough = session.lastObservedPlaybackTime >= settings.minimumSkipListeningSeconds
        let leftBeforeThreshold = progress < settings.skipThresholdPercentage

        if listenedLongEnough && leftBeforeThreshold {
            item.skipCount += 1
            item.lastSkippedAt = .now
            item.updatedAt = .now
            logHistory(
                item: item,
                playlist: playlist,
                eventType: .skipCounted,
                source: .playback,
                session: session,
                message: "\(item.skipCount) skips before \(Int(settings.skipThresholdPercentage))%",
                context: context
            )

            if item.skipCount >= settings.evictAfterSkips {
                let shouldAutoEvict = playlist.role == .oneTruePlaylist
                    || settings.triageAutoEvictsOnSkipCount
                if shouldAutoEvict {
                    evict(
                        item,
                        playlist: playlist,
                        reason: .skipCount,
                        source: .playbackRule,
                        message: "\(item.skipCount) skips before \(Int(settings.skipThresholdPercentage))%",
                        context: context
                    )
                } else {
                    logHistory(
                        item: item,
                        playlist: playlist,
                        eventType: .skipIgnored,
                        source: .playback,
                        session: session,
                        message: "Triage auto-eviction is off",
                        context: context
                    )
                }
            }
        } else {
            logHistory(
                item: item,
                playlist: playlist,
                eventType: .skipIgnored,
                source: .playback,
                session: session,
                message: listenedLongEnough ? "Past skip threshold" : "Below minimum listening time",
                context: context
            )
        }
    }

    static func countPlaythrough(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        session: TrackPlaySession,
        settings: OverplaySettings,
        context: ModelContext
    ) {
        item.playthroughCount += 1
        item.lastPlayedAt = .now
        if settings.playthroughResetsSkipCount {
            item.skipCount = 0
        }
        item.updatedAt = .now
        logHistory(
            item: item,
            playlist: playlist,
            eventType: .playthrough,
            source: .playback,
            session: session,
            message: "Reached \(Int(settings.playthroughThresholdPercentage))%",
            context: context
        )
    }

    static func evict(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        reason: EvictionReason = .manual,
        source: EvictionSource = .user,
        message: String? = nil,
        context: ModelContext
    ) {
        item.evictedAt = .now
        item.evictionReason = reason
        item.evictionSource = source
        item.updatedAt = .now
        EventRepository.logHistory(
            playlistID: playlist.id,
            trackID: item.trackID,
            eventType: .evicted,
            source: source.historySource,
            skipCountAtEvent: item.skipCount,
            message: message,
            in: context
        )
    }

    static func restore(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord?,
        context: ModelContext
    ) {
        item.evictedAt = nil
        item.evictionReason = nil
        item.evictionSource = nil
        item.updatedAt = .now
        EventRepository.logHistory(
            playlistID: playlist?.id ?? item.playlistID,
            trackID: item.trackID,
            eventType: .restored,
            source: .user,
            skipCountAtEvent: item.skipCount,
            message: "Restored locally",
            in: context
        )
    }

    private static func logHistory(
        item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        eventType: HistoryEventType,
        source: HistoryEventSource,
        session: TrackPlaySession,
        message: String?,
        context: ModelContext
    ) {
        EventRepository.logHistory(
            playlistID: playlist.id,
            trackID: item.trackID,
            eventType: eventType,
            source: source,
            skipCountAtEvent: item.skipCount,
            positionSeconds: session.lastObservedPlaybackTime,
            durationSeconds: session.durationSeconds,
            progressPercentage: session.progressPercentage,
            message: message,
            in: context
        )
    }
}

private extension EvictionSource {
    var historySource: HistoryEventSource {
        switch self {
        case .user:
            .user
        case .playbackRule:
            .playback
        case .appleMusicSync:
            .appleMusic
        }
    }
}
