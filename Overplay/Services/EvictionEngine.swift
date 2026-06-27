import Foundation
import SwiftData

struct TrackPlaySession: Equatable {
    var trackID: String
    var localTrackID: String?
    var sessionStartDate: Date
    var lastObservedPlaybackTime: Double
    var durationSeconds: Double?
    var hasEvaluated: Bool

    init(
        trackID: String,
        localTrackID: String? = nil,
        sessionStartDate: Date,
        lastObservedPlaybackTime: Double,
        durationSeconds: Double?,
        hasEvaluated: Bool
    ) {
        self.trackID = trackID
        self.localTrackID = localTrackID
        self.sessionStartDate = sessionStartDate
        self.lastObservedPlaybackTime = lastObservedPlaybackTime
        self.durationSeconds = durationSeconds
        self.hasEvaluated = hasEvaluated
    }

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
        if transitionWasNaturalCompletion {
            countPlaythrough(item, playlist: playlist, session: session, settings: settings, context: context)
            return
        }

        let progress = session.progressPercentage ?? 0
        let listenedLongEnough = session.lastObservedPlaybackTime >= settings.minimumSkipListeningSeconds
        let leftBeforeThreshold = progress < settings.skipThresholdPercentage

        if listenedLongEnough && leftBeforeThreshold {
            let previousSkipCount = item.skipCount
            item.skipCount += 1
            item.lastSkippedAt = .now
            item.updatedAt = .now
            TrackMetadataDiagnostics.log(
                "counted skip playlist=\(TrackMetadataDiagnostics.describe(playlist)) itemID=\(item.id.uuidString) trackID=\(item.trackID.uuidString) previousSkips=\(previousSkipCount) newSkips=\(item.skipCount) elapsed=\(String(format: "%.1f", session.lastObservedPlaybackTime)) progress=\(String(format: "%.1f", progress)) threshold=\(settings.skipThresholdPercentage)"
            )
            logHistory(
                item: item,
                playlist: playlist,
                eventType: .skipCounted,
                source: .playback,
                session: session,
                message: "\(item.skipCount) skips before \(Int(settings.skipThresholdPercentage))%",
                context: context
            )
        } else {
            TrackMetadataDiagnostics.log(
                "ignored skip playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item)) elapsed=\(String(format: "%.1f", session.lastObservedPlaybackTime)) progress=\(String(format: "%.1f", progress)) listenedLongEnough=\(listenedLongEnough) leftBeforeThreshold=\(leftBeforeThreshold)"
            )
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
        let previousSkipCount = item.skipCount
        let previousPlaythroughCount = item.playthroughCount
        item.playthroughCount += 1
        item.lastPlayedAt = .now
        item.updatedAt = .now
        TrackMetadataDiagnostics.log(
            "counted playthrough playlist=\(TrackMetadataDiagnostics.describe(playlist)) itemID=\(item.id.uuidString) trackID=\(item.trackID.uuidString) previousSkips=\(previousSkipCount) newSkips=\(item.skipCount) previousPlays=\(previousPlaythroughCount) newPlays=\(item.playthroughCount) progress=\(session.progressPercentage.map { String(format: "%.1f", $0) } ?? "nil")"
        )
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
