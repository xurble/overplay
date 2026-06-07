import Foundation
import SwiftData

enum TrackHealthActionService {
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
