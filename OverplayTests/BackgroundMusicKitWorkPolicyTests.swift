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
