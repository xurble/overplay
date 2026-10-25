import Foundation
import Testing
@testable import Overplay

/// `LOAD-001`: automatic Apple Music work never competes with playback.
struct BackgroundMusicKitWorkPolicyTests {
    @Test func periodicPlayCountRefreshWaitsWhilePlayingOrFailing() {
        #expect(BackgroundMusicKitWorkPolicy.allowsAutomaticPlayCountRefresh(isPlaying: false, hasPlaybackFailure: false))
        #expect(!BackgroundMusicKitWorkPolicy.allowsAutomaticPlayCountRefresh(isPlaying: true, hasPlaybackFailure: false))
        #expect(!BackgroundMusicKitWorkPolicy.allowsAutomaticPlayCountRefresh(isPlaying: false, hasPlaybackFailure: true))
        #expect(BackgroundMusicKitWorkPolicy.periodicPlayCountInterval == .seconds(900))
    }

    /// An old Library list in CarPlay waits for quiet playback: MusicKit
    /// reports nothing about how much of a song is buffered.
    @Test func staleLibraryRefreshWaitsWhilePlayingStartingOrFailing() {
        typealias Activity = BackgroundMusicKitWorkPolicy.PlaybackActivity
        #expect(BackgroundMusicKitWorkPolicy.allowsStaleLibraryRefresh(Activity()))
        #expect(!BackgroundMusicKitWorkPolicy.allowsStaleLibraryRefresh(Activity(isPlaying: true)))
        #expect(!BackgroundMusicKitWorkPolicy.allowsStaleLibraryRefresh(Activity(isStarting: true)))
        #expect(!BackgroundMusicKitWorkPolicy.allowsStaleLibraryRefresh(Activity(hasFailure: true)))
    }

    /// Runs the wait over scripted checks; returns how many checks it made.
    /// Past the script playback is quiet, so a wait that would return too late
    /// ends, and is reported as nil, rather than hanging.
    private func checksBeforeRefresh(_ script: [BackgroundMusicKitWorkPolicy.PlaybackActivity]) async -> Int? {
        var checks = 0
        var sleeps: [Duration] = []
        await BackgroundMusicKitWorkPolicy.waitForQuietPlayback({
            defer { checks += 1 }
            return checks < script.count ? script[checks] : .init()
        }, sleep: { sleeps.append($0) })
        #expect(sleeps.allSatisfy { $0 == BackgroundMusicKitWorkPolicy.staleLibraryRefreshRecheck })
        #expect(sleeps.count == checks - 1)
        return checks <= script.count ? checks : nil
    }

    @Test func staleLibraryRefreshNeedsTwoQuietChecksInARow() async {
        typealias Activity = BackgroundMusicKitWorkPolicy.PlaybackActivity
        let quiet = Activity()
        #expect(await checksBeforeRefresh([quiet, quiet]) == 2)
        // A start between quiet checks starts the count again.
        #expect(await checksBeforeRefresh([quiet, Activity(isStarting: true), quiet, quiet]) == 4)
        #expect(await checksBeforeRefresh([Activity(isPlaying: true), quiet, Activity(hasFailure: true), quiet, quiet]) == 5)
    }

    @Test func nothingAutomaticStartsInTheFirstMinuteAfterLaunch() {
        let launched = ContinuousClock.now
        let saved = BackgroundMusicKitWorkPolicy.launchedAt
        defer { BackgroundMusicKitWorkPolicy.launchedAt = saved }
        BackgroundMusicKitWorkPolicy.launchedAt = launched

        #expect(BackgroundMusicKitWorkPolicy.launchQuietPeriod == .seconds(60))
        #expect(BackgroundMusicKitWorkPolicy.launchQuietEnds == launched + .seconds(60))
        #expect(BackgroundMusicKitWorkPolicy.isInLaunchQuietPeriod(now: launched))
        #expect(BackgroundMusicKitWorkPolicy.isInLaunchQuietPeriod(now: launched + .seconds(59)))
        #expect(!BackgroundMusicKitWorkPolicy.isInLaunchQuietPeriod(now: launched + .seconds(60)))
    }

    @Test func automaticSyncPausesDuringAPlaybackFailure() {
        #expect(BackgroundMusicKitWorkPolicy.allowsAutomaticSync(hasPlaybackFailure: false))
        #expect(!BackgroundMusicKitWorkPolicy.allowsAutomaticSync(hasPlaybackFailure: true))
    }

    @Test func libraryDiscoveryRunsAtMostEverySixHoursAndNeverWhilePlaying() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(BackgroundMusicKitWorkPolicy.allowsLibraryDiscovery(lastDiscoveryAt: nil, now: now, isPlaying: false))
        #expect(!BackgroundMusicKitWorkPolicy.allowsLibraryDiscovery(lastDiscoveryAt: nil, now: now, isPlaying: true))
        #expect(!BackgroundMusicKitWorkPolicy.allowsLibraryDiscovery(
            lastDiscoveryAt: now.addingTimeInterval(-5 * 3600), now: now, isPlaying: false))
        #expect(BackgroundMusicKitWorkPolicy.allowsLibraryDiscovery(
            lastDiscoveryAt: now.addingTimeInterval(-6 * 3600), now: now, isPlaying: false))
    }
}
