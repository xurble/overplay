import Foundation
import OSLog
import SwiftData

enum TrackHealthActionService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Overplay",
        category: "TrackHealth"
    )

    static func keepCurrentTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        protect: Bool,
        message: String,
        in context: ModelContext
    ) throws {
        item.skipCount = 0
        if protect {
            item.protected = true
        }
        item.updatedAt = .now
        EventRepository.logHistory(
            playlistID: playlist.id,
            trackID: item.trackID,
            eventType: .skipIgnored,
            source: .user,
            skipCountAtEvent: item.skipCount,
            message: message,
            in: context
        )
        try context.save()
    }

    static func resetSkipCount(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        message: String,
        in context: ModelContext
    ) throws {
        let previousSkipCount = item.skipCount
        item.skipCount = 0
        item.updatedAt = .now
        EventRepository.logHistory(
            playlistID: playlist.id,
            trackID: item.trackID,
            eventType: .skipIgnored,
            source: .user,
            skipCountAtEvent: item.skipCount,
            message: message,
            in: context
        )
        try context.save()
        logger.info(
            "Reset skip count for playlist \(playlist.musicPlaylistID, privacy: .public), item \(item.id.uuidString, privacy: .public), previous \(previousSkipCount, privacy: .public)"
        )
    }

    static func protectTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        message: String,
        in context: ModelContext
    ) throws {
        item.protected = true
        item.updatedAt = .now
        EventRepository.logHistory(
            playlistID: playlist.id,
            trackID: item.trackID,
            eventType: .skipIgnored,
            source: .user,
            skipCountAtEvent: item.skipCount,
            message: message,
            in: context
        )
        try context.save()
    }

    static func evictTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        reason: EvictionReason = .manual,
        source: EvictionSource = .user,
        message: String,
        in context: ModelContext
    ) throws {
        EvictionEngine.evict(
            item,
            playlist: playlist,
            reason: reason,
            source: source,
            message: message,
            context: context
        )
        try context.save()
    }

    static func restoreTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord?,
        in context: ModelContext
    ) throws {
        EvictionEngine.restore(item, playlist: playlist, context: context)
        try context.save()
    }
}
