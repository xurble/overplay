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
        TrackMetadataDiagnostics.log(
            "manual keep saved playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item)) protect=\(protect)"
        )
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
        TrackMetadataDiagnostics.log(
            "manual reset skip count saved playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item)) previousSkips=\(previousSkipCount)"
        )
    }

    static func protectTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        message: String,
        in context: ModelContext
    ) throws {
        try setProtected(
            item,
            playlist: playlist,
            isProtected: true,
            message: message,
            in: context
        )
    }

    static func setProtected(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        isProtected: Bool,
        message: String,
        in context: ModelContext
    ) throws {
        item.protected = isProtected
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
        TrackMetadataDiagnostics.log(
            "manual protected state saved playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item)) isProtected=\(isProtected)"
        )
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
        TrackMetadataDiagnostics.log(
            "manual eviction saved playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item)) reason=\(reason.rawValue) source=\(source.rawValue)"
        )
    }

    static func restoreTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord?,
        in context: ModelContext
    ) throws {
        EvictionEngine.restore(item, playlist: playlist, context: context)
        try context.save()
        TrackMetadataDiagnostics.log(
            "manual restore saved playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item))"
        )
    }
}
