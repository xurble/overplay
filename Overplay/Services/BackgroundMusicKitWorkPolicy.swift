import Foundation

/// When automatic Apple Music work may run (`LOAD-001`). Playback comes first:
/// nothing automatic competes with it while it plays, and nothing at all runs
/// while a playback failure is active, so Overplay adds no load to a struggling
/// Apple Music stack. Explicit user actions are never gated here.
enum BackgroundMusicKitWorkPolicy {
    /// Nothing automatic starts in the first minute after launch: Overplay is
    /// launched to play music. On 2026-10-18 a CarPlay cold start's prepare
    /// timed out while launch-time sync and play-count work were running.
    static let launchQuietPeriod: Duration = .seconds(60)
    /// When this process launched; `OverplayApp` sets it first thing.
    static var launchedAt = ContinuousClock.now
    static var launchQuietEnds: ContinuousClock.Instant { launchedAt + launchQuietPeriod }

    static func isInLaunchQuietPeriod(now: ContinuousClock.Instant = .now) -> Bool {
        now < launchQuietEnds
    }

    static let periodicPlayCountInterval: Duration = .seconds(15 * 60)
    static let discoveryInterval: TimeInterval = 6 * 60 * 60

    static func allowsAutomaticSync(hasPlaybackFailure: Bool) -> Bool {
        !hasPlaybackFailure
    }

    static func allowsAutomaticPlayCountRefresh(isPlaying: Bool, hasPlaybackFailure: Bool) -> Bool {
        !isPlaying && !hasPlaybackFailure
    }

    /// A Library list that is merely old waits for a pause: the cached copy
    /// shows meanwhile. MusicKit reports nothing about how much of a song is
    /// buffered, so "not playing" is the only safe moment.
    static func allowsStaleLibraryRefresh(isPlaying: Bool, hasPlaybackFailure: Bool) -> Bool {
        !isPlaying && !hasPlaybackFailure
    }

    /// How often a waiting stale refresh looks again.
    static let staleLibraryRefreshRecheck: Duration = .seconds(30)

    static func allowsLibraryDiscovery(lastDiscoveryAt: Date?, now: Date, isPlaying: Bool) -> Bool {
        guard !isPlaying else { return false }
        return lastDiscoveryAt.map { now.timeIntervalSince($0) >= discoveryInterval } ?? true
    }
}
