import Foundation

enum NowPlayingProgressPhase: Equatable, Sendable {
    case normal
    case danger
    case safe
}

struct NowPlayingPresentation: Equatable, Sendable {
    let trackID: String?
    let title: String
    let artistName: String
    let albumTitle: String?
    let progress: Double
    let progressPhase: NowPlayingProgressPhase
    let elapsedSeconds: Double
    let durationSeconds: Double?
    let isPlaying: Bool
    let elapsedText: String
    let durationText: String
    let skipCount: Int
    let playthroughCount: Int
    let skipCountText: String
    let healthMetricText: String
    let isEvicted: Bool
    let isProtected: Bool

    init(
        trackID: String? = nil,
        title: String?,
        artistName: String?,
        albumTitle: String?,
        progress: Double,
        elapsedSeconds: Double,
        durationSeconds: Double?,
        isPlaying: Bool = false,
        skipThresholdPercentage: Double = 50,
        minimumSkipListeningSeconds: Double = 10,
        playthroughThresholdPercentage: Double = 90,
        skipCount: Int,
        playthroughCount: Int = 0,
        evictAfterSkips: Int,
        isEvicted: Bool,
        isProtected: Bool
    ) {
        self.trackID = trackID
        self.title = title ?? "Nothing playing"
        self.artistName = artistName ?? "Choose Play Overplay from the dashboard."
        self.albumTitle = albumTitle
        self.progress = progress
        self.elapsedSeconds = elapsedSeconds
        self.durationSeconds = durationSeconds
        self.isPlaying = isPlaying
        self.progressPhase = Self.progressPhase(
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds,
            skipThresholdPercentage: skipThresholdPercentage,
            minimumSkipListeningSeconds: minimumSkipListeningSeconds,
            playthroughThresholdPercentage: playthroughThresholdPercentage
        )
        self.elapsedText = Self.formatTime(elapsedSeconds)
        self.durationText = Self.formatTime(durationSeconds ?? 0)
        self.skipCount = skipCount
        self.playthroughCount = playthroughCount
        self.skipCountText = Self.pluralized(skipCount, singular: "skip")
        self.healthMetricText = "\(Self.pluralized(playthroughCount, singular: "play")) / \(Self.pluralized(skipCount, singular: "skip"))"
        _ = evictAfterSkips
        self.isEvicted = isEvicted
        self.isProtected = isProtected
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let totalSeconds = max(Int(seconds), 0)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    static func pluralized(_ count: Int, singular: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(singular)s"
    }

    static func progressPhase(
        elapsedSeconds: Double,
        durationSeconds: Double?,
        skipThresholdPercentage: Double,
        minimumSkipListeningSeconds: Double,
        playthroughThresholdPercentage: Double
    ) -> NowPlayingProgressPhase {
        guard let durationSeconds, durationSeconds > 0 else {
            return .normal
        }

        let progressPercentage = PlaybackSessionEvaluationService.progressPercentage(
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds
        )
        if progressPercentage >= playthroughThresholdPercentage {
            return .safe
        }
        if PlaybackSessionEvaluationService.skipWouldCount(
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds,
            skipThresholdPercentage: skipThresholdPercentage,
            minimumSkipListeningSeconds: minimumSkipListeningSeconds
        ) {
            return .danger
        }
        return .normal
    }
}
