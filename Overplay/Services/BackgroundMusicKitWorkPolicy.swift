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

    /// What playback is doing, as background work sees it.
    struct PlaybackActivity: Equatable, Sendable {
        var isPlaying = false
        /// A start is resolving or loading, or a player call is unanswered.
        var isStarting = false
        var hasFailure = false
    }

    /// In CarPlay, a Library list that is merely old waits for playback to be
    /// quiet: not playing, not starting and not failing. The cached copy shows
    /// meanwhile. MusicKit reports nothing about how much of a song is
    /// buffered, so a quiet player is the only moment known to be safe.
    static func allowsStaleLibraryRefresh(_ activity: PlaybackActivity) -> Bool {
        !activity.isPlaying && !activity.isStarting && !activity.hasFailure
    }

    static func allowsPlaylistPresenceCheck(
        _ activity: PlaybackActivity,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        !isInLaunchQuietPeriod(now: now) && allowsStaleLibraryRefresh(activity)
    }

    /// How often a waiting stale refresh looks again.
    static let staleLibraryRefreshRecheck: Duration = .seconds(30)
    /// Quiet checks in a row a refresh needs: one quiet moment may be the
    /// gap between songs or between pressing Play and the start being seen.
    static let staleLibraryRefreshQuietChecks = 2

    /// Returns once playback has been quiet at `staleLibraryRefreshQuietChecks`
    /// checks in a row, `staleLibraryRefreshRecheck` apart. A refresh that has
    /// begun runs to its end, so one may still overlap a start that follows.
    static func waitForQuietPlayback(
        _ activity: () -> PlaybackActivity,
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async {
        var quiet = 0
        while true {
            quiet = allowsStaleLibraryRefresh(activity()) ? quiet + 1 : 0
            if quiet >= staleLibraryRefreshQuietChecks { return }
            await sleep(staleLibraryRefreshRecheck)
        }
    }

    static func allowsLibraryDiscovery(lastDiscoveryAt: Date?, now: Date, isPlaying: Bool) -> Bool {
        guard !isPlaying else { return false }
        return lastDiscoveryAt.map { now.timeIntervalSince($0) >= discoveryInterval } ?? true
    }
}
