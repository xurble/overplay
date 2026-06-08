import Foundation

struct NowPlayingPresentation: Equatable, Sendable {
    let trackID: String?
    let title: String
    let artistName: String
    let albumTitle: String?
    let progress: Double
    let elapsedText: String
    let durationText: String
    let skipCount: Int
    let skipCountText: String
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
        skipCount: Int,
        evictAfterSkips: Int,
        isEvicted: Bool,
        isProtected: Bool
    ) {
        self.trackID = trackID
        self.title = title ?? "Nothing playing"
        self.artistName = artistName ?? "Choose Play Overplay from the dashboard."
        self.albumTitle = albumTitle
        self.progress = progress
        self.elapsedText = Self.formatTime(elapsedSeconds)
        self.durationText = Self.formatTime(durationSeconds ?? 0)
        self.skipCount = skipCount
        self.skipCountText = "Skips: \(skipCount) / \(evictAfterSkips)"
        self.isEvicted = isEvicted
        self.isProtected = isProtected
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let totalSeconds = max(Int(seconds), 0)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}
