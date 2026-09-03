import Foundation

/// Decides when Overplay should write to `MPNowPlayingInfoCenter`.
///
/// Two problems this solves, both of which come from Overplay playing
/// through `ApplicationMusicPlayer` — an out-of-process player whose audio
/// the Music app's engine owns, and for which the system already publishes
/// its own Now Playing information.
///
/// 1. Overplay used to rewrite the whole payload on every 1 Hz monitor
///    tick. The system extrapolates position from elapsed time plus playback
///    rate, so a write is only needed when the described state actually
///    changes, or when the real player position has drifted away from what
///    the system would have extrapolated (a seek or an external skip).
/// 2. Overplay used to publish a restored track at launch, before it owned
///    any playback. That takes the Now Playing session away from whatever
///    genuinely is playing — possibly the Music app itself. Publishing now
///    requires the shared player to actually hold one of our entries, and
///    Overplay never clears a session it never published.
enum NowPlayingPublishPolicy {
    /// How far the real player position may drift from the extrapolated one
    /// before a fresh write is needed. Also the accuracy Overplay accepts
    /// for the system's own position display.
    static let elapsedDriftTolerance: TimeInterval = 2
    /// Heartbeat re-anchor while playing. Not strictly required — the drift
    /// check is measured against the live player position — but it keeps one
    /// cheap correction per minute instead of one per second.
    static let reanchorInterval: TimeInterval = 60

    /// The part of the payload whose change always warrants a write.
    struct Identity: Equatable, Sendable {
        var title: String
        var artistName: String
        var albumTitle: String?
        var durationSeconds: Double?
        var isPlaying: Bool
    }

    struct Published: Equatable, Sendable {
        var identity: Identity
        var elapsedSeconds: Double
        var publishedAt: Date
    }

    enum Decision: Equatable, Sendable {
        case publish
        case clear
        case skip
    }

    static func decision(
        identity: Identity?,
        elapsedSeconds: Double,
        ownsPlayback: Bool,
        lastPublished: Published?,
        now: Date
    ) -> Decision {
        // Overplay's queue is not loaded in the shared player, so it has no
        // claim on the Now Playing session. Retract only what it published.
        guard ownsPlayback else {
            return lastPublished == nil ? .skip : .clear
        }

        // The player holds our entry but the current track is momentarily
        // undescribable (mid-transition, hydrating). Keep the last payload
        // rather than flapping the session to empty and back.
        guard let identity else { return .skip }

        guard let lastPublished else { return .publish }
        guard lastPublished.identity == identity else { return .publish }

        let secondsSincePublish = now.timeIntervalSince(lastPublished.publishedAt)
        if secondsSincePublish >= reanchorInterval {
            return .publish
        }

        // What the system currently believes the position is, given the
        // elapsed time and rate last handed to it.
        let extrapolatedElapsed = identity.isPlaying
            ? lastPublished.elapsedSeconds + max(secondsSincePublish, 0)
            : lastPublished.elapsedSeconds
        return abs(elapsedSeconds - extrapolatedElapsed) > elapsedDriftTolerance
            ? .publish
            : .skip
    }
}
