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
                evict(
                    track,
                    reason: "\(track.skipCount) skips before \(Int(settings.skipThresholdPercentage))%",
                    context: context
                )
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
}
