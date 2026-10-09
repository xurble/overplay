import Foundation
import OSLog

enum TrackMetadataDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "TrackMetadata"
    )

    /// Also kept in the activity log's launch files, so a decision made on a
    /// device can be read after the fact (#84).
    static func log(_ message: String) {
        MusicKitActivityLog.shared.record(.diagnosticNote, detail: message)
        #if DEBUG
        logger.debug("\(message, privacy: .public)")
        #endif
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
