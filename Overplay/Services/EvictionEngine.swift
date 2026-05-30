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
        session: TrackPlaySession,
        transitionWasNaturalCompletion: Bool,
        settings: OverplaySettings,
        context: ModelContext
    ) throws {
        guard !session.hasEvaluated else { return }
        guard let track = try TrackRepository.track(id: session.trackID, in: context) else { return }
        guard !track.isEvicted else {
            EventRepository.log(
                trackID: session.trackID,
                eventType: "skipIgnored",
                positionSeconds: session.lastObservedPlaybackTime,
                durationSeconds: session.durationSeconds,
                progressPercentage: session.progressPercentage,
                reason: "Already evicted",
                in: context
            )
            return
        }
        guard !track.protected else {
            EventRepository.log(
                trackID: session.trackID,
                eventType: "skipIgnored",
                positionSeconds: session.lastObservedPlaybackTime,
                durationSeconds: session.durationSeconds,
                progressPercentage: session.progressPercentage,
                reason: "Protected",
                in: context
            )
            return
        }

        if transitionWasNaturalCompletion {
            countPlaythrough(track, session: session, settings: settings, context: context)
            return
        }

        let progress = session.progressPercentage ?? 0
        let listenedLongEnough = session.lastObservedPlaybackTime >= settings.minimumSkipListeningSeconds
        let leftBeforeThreshold = progress < settings.skipThresholdPercentage

        if listenedLongEnough && leftBeforeThreshold {
            track.skipCount += 1
            track.lastSkippedAt = .now
            track.updatedAt = .now
            EventRepository.log(
                trackID: track.id,
                eventType: "skipCounted",
                positionSeconds: session.lastObservedPlaybackTime,
                durationSeconds: session.durationSeconds,
                progressPercentage: progress,
                reason: "\(track.skipCount) skips before \(Int(settings.skipThresholdPercentage))%",
                in: context
            )

            if track.skipCount >= settings.evictAfterSkips {
                if try canAutomaticallyEvict(track, in: context) {
                    evict(
                        track,
                        reason: "\(track.skipCount) skips before \(Int(settings.skipThresholdPercentage))%",
                        context: context
                    )
                } else {
                    EventRepository.log(
                        trackID: track.id,
                        eventType: "skipIgnored",
                        positionSeconds: session.lastObservedPlaybackTime,
                        durationSeconds: session.durationSeconds,
                        progressPercentage: progress,
                        reason: "Automatic eviction is limited to the One True Playlist",
                        in: context
                    )
                }
            }
        } else {
            EventRepository.log(
                trackID: track.id,
                eventType: "skipIgnored",
                positionSeconds: session.lastObservedPlaybackTime,
                durationSeconds: session.durationSeconds,
                progressPercentage: progress,
                reason: listenedLongEnough ? "Past skip threshold" : "Below minimum listening time",
                in: context
            )
        }
    }

    static func countPlaythrough(
        _ track: TrackedTrack,
        session: TrackPlaySession,
        settings: OverplaySettings,
        context: ModelContext
    ) {
        track.playthroughCount += 1
        track.lastPlayedAt = .now
        if settings.playthroughResetsSkipCount {
            track.skipCount = 0
        }
        track.updatedAt = .now
        EventRepository.log(
            trackID: track.id,
            eventType: "playthrough",
            positionSeconds: session.lastObservedPlaybackTime,
            durationSeconds: session.durationSeconds,
            progressPercentage: session.progressPercentage,
            reason: "Reached \(Int(settings.playthroughThresholdPercentage))%",
            in: context
        )
    }

    static func keep(_ track: TrackedTrack, settings: OverplaySettings, context: ModelContext) {
        track.skipCount = 0
        if settings.protectKeptTracks {
            track.protected = true
        }
        track.updatedAt = .now
        EventRepository.log(trackID: track.id, eventType: "skipIgnored", reason: "Kept by user", in: context)
    }

    static func evict(_ track: TrackedTrack, reason: String, context: ModelContext) {
        track.evictedAt = .now
        track.evictionReason = reason
        track.updatedAt = .now
        EventRepository.log(trackID: track.id, eventType: "evicted", reason: reason, in: context)
    }

    static func restore(_ track: TrackedTrack, context: ModelContext) {
        track.evictedAt = nil
        track.evictionReason = nil
        track.updatedAt = .now
        EventRepository.log(trackID: track.id, eventType: "restored", reason: "Restored locally", in: context)
    }

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
                if playlist.role == .oneTruePlaylist {
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
                        message: "Automatic eviction is limited to the One True Playlist",
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
        item.removedFromRemoteAt = nil
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

    private static func canAutomaticallyEvict(_ track: TrackedTrack, in context: ModelContext) throws -> Bool {
        guard let playlistID = track.playlistID,
              let playlist = try PlaylistRepository.playlist(musicPlaylistID: playlistID, in: context) else {
            return true
        }

        return playlist.role == .oneTruePlaylist
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
