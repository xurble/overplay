import Foundation
import SwiftData

enum TrackActionService {
    @discardableResult
    static func resetSkipCount(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        message: String,
        protectingItemID: UUID? = nil,
        in context: ModelContext
    ) throws -> Bool {
        let previousSkipCount = item.skipCount
        item.hasRecordedActivity = item.hasListeningHistory
        try ListenLedger.resetSkips(trackID: item.trackID, in: context)
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
        if item.evictedAt != nil {
            try TrackRetentionPolicy.deleteIfUnowned(item, protectingItemID: protectingItemID, in: context)
        }
        TrackMetadataDiagnostics.log(
            "manual reset skip count saved playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item)) previousSkips=\(previousSkipCount)"
        )
        let retained = !item.isDeleted
        try context.save()
        return retained
    }

    @discardableResult
    static func evictTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        reason: EvictionReason = .manual,
        source: EvictionSource = .user,
        message: String,
        in context: ModelContext
    ) throws -> Bool {
        try TrackLocationService.retire(
            item,
            playlist: playlist,
            reason: reason,
            source: source,
            message: message,
            in: context
        )
        let retained = !item.isDeleted
        TrackMetadataDiagnostics.log(
            "manual eviction saved playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item)) reason=\(reason.rawValue) source=\(source.rawValue)"
        )
        try context.save()
        return retained
    }

    static func restoreTrack(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord?,
        in context: ModelContext
    ) throws {
        try TrackLocationService.moveToTriage(item, explicitKeep: true, in: context)
        try context.save()
        TrackMetadataDiagnostics.log(
            "manual restore saved playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item))"
        )
    }

    /// An active One True Playlist song back to the Inbox, kept. Like a
    /// retirement it is suppressed in the Apple Music playlist, so a sync
    /// before the removal lands cannot promote it back.
    static func moveToInbox(
        _ item: PlaylistItemRecord,
        from playlist: PlaylistRecord,
        in context: ModelContext
    ) throws {
        if !item.suppressedOTPMusicPlaylistIDs.contains(playlist.musicPlaylistID) {
            item.suppressedOTPMusicPlaylistIDs.append(playlist.musicPlaylistID)
        }
        try TrackLocationService.moveToTriage(item, explicitKeep: true, in: context)
        try context.save()
        TrackMetadataDiagnostics.log(
            "manual move to the Inbox saved playlist=\(TrackMetadataDiagnostics.describe(playlist)) item=\(TrackMetadataDiagnostics.describe(item))"
        )
    }
}
