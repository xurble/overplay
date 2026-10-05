import Foundation

/// When automatic Apple Music work may run (`LOAD-001`). Playback comes first:
/// nothing automatic competes with it while it plays, and nothing at all runs
/// while a playback failure is active, so Overplay adds no load to a struggling
/// Apple Music stack. Explicit user actions are never gated here.
enum BackgroundMusicKitWorkPolicy {
    static let periodicPlayCountInterval: Duration = .seconds(15 * 60)
    static let discoveryInterval: TimeInterval = 6 * 60 * 60

    static func allowsAutomaticSync(hasPlaybackFailure: Bool) -> Bool {
        !hasPlaybackFailure
    }

    static func allowsAutomaticPlayCountRefresh(isPlaying: Bool, hasPlaybackFailure: Bool) -> Bool {
        !isPlaying && !hasPlaybackFailure
    }

    static func allowsLibraryDiscovery(lastDiscoveryAt: Date?, now: Date, isPlaying: Bool) -> Bool {
        guard !isPlaying else { return false }
        return lastDiscoveryAt.map { now.timeIntervalSince($0) >= discoveryInterval } ?? true
    }
}
