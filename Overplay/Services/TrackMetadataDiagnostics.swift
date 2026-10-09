import Foundation
import OSLog
import Synchronization

enum TrackMetadataDiagnostics {
    /// Some notes come from code that runs on every render, so an identical
    /// note is persisted at most once a minute.
    static let repeatInterval: TimeInterval = 60
    private static let recentNotes = Mutex<[String: Date]>([:])
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "TrackMetadata"
    )

    /// Also kept in the activity log's launch files, so a decision made on a
    /// device can be read after the fact (#84).
    static func log(_ message: String) {
        if shouldPersist(message) {
            MusicKitActivityLog.shared.record(.diagnosticNote, detail: message)
        }
        #if DEBUG
        logger.debug("\(message, privacy: .public)")
        #endif
    }

    static func shouldPersist(_ message: String, now: Date = .now) -> Bool {
        recentNotes.withLock { recent in
            if let last = recent[message], now.timeIntervalSince(last) < repeatInterval { return false }
            if recent.count >= 200 { recent = recent.filter { now.timeIntervalSince($0.value) < repeatInterval } }
            recent[message] = now
            return true
        }
    }

    static func describe(_ playlist: PlaylistRecord?) -> String {
        guard let playlist else { return "playlist=nil" }
        return "playlist(id=\(playlist.id.uuidString), musicID=\(playlist.musicPlaylistID), role=\(playlist.role.rawValue))"
    }

    static func describe(_ item: PlaylistItemRecord?) -> String {
        guard let item else { return "item=nil" }
        return "item(id=\(item.id.uuidString), playlistID=\(item.playlistID.uuidString), trackID=\(item.trackID.uuidString), skips=\(item.skipCount), plays=\(item.playthroughCount), evicted=\(item.evictedAt != nil))"
    }

    static func describe(_ track: CurrentPlaybackTrack?) -> String {
        guard let track else { return "currentTrack=nil" }
        return "currentTrack(id=\(track.id), title=\(track.title), skips=\(track.skipCount), plays=\(track.playthroughCount), evicted=\(track.isEvicted))"
    }
}
