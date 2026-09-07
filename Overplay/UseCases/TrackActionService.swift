import Foundation
import SwiftData

enum TrackActionService {
    /// Kept as the name the UI uses. With auto-eviction gone this is exactly
    /// a skip-count reset — there is no protection left to apply.
    static func keepCurrentTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        message: String,
        in context: ModelContext
    ) throws {
        try resetSkipCount(item, playlist: playlist, message: message, in: context)
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
