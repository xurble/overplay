import Foundation
import SwiftData

/// Durable movement shared by app actions, source intake, and remote OTP sync.
enum TrackLocationService {
    static func moveToOTP(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        entryID: String? = nil,
        source: HistoryEventSource,
        logEvent: Bool = true,
        at date: Date = .now,
        in context: ModelContext
    ) {
        let previousPlaylistID = item.playlistID
        item.locationChangedAt = date
        item.playlistID = playlist.id
        item.musicPlaylistEntryID = entryID
        item.evictedAt = nil
        item.evictionReason = nil
        item.evictionSource = nil
        item.suppressedOTPMusicPlaylistIDs.removeAll { $0 == playlist.musicPlaylistID }
        item.updatedAt = date
        if logEvent { EventRepository.logHistory(
            playlistID: previousPlaylistID, trackID: item.trackID,
            eventType: .promoted, source: source, skipCountAtEvent: item.skipCount,
            remoteMutationStatus: source == .user ? .succeeded : nil,
            message: "Moved to \(playlist.name)", in: context
        ) }
    }

    static func moveToTriage(
        _ item: PlaylistItemRecord,
        explicitKeep: Bool,
        source: HistoryEventSource = .user,
        logEvent: Bool = true,
        at date: Date = .now,
        in context: ModelContext
    ) throws {
        let bucket = try PlaylistRepository.triageBucket(in: context)
        item.locationChangedAt = date
        item.playlistID = bucket.id
        item.musicPlaylistEntryID = nil
        item.isExplicitlyKept = item.isExplicitlyKept || explicitKeep
        item.evictedAt = nil
        item.evictionReason = nil
        item.evictionSource = nil
        item.updatedAt = date
        if logEvent { EventRepository.logHistory(
            playlistID: bucket.id, trackID: item.trackID, eventType: .restored,
            source: source, skipCountAtEvent: item.skipCount,
            message: "Moved to Triage", in: context
        ) }
    }

    static func retire(
        _ item: PlaylistItemRecord,
        playlist: PlaylistRecord,
        reason: EvictionReason,
        source: EvictionSource,
        message: String,
        preserveForMerge: Bool = false,
        in context: ModelContext
    ) throws {
        let bucket = try PlaylistRepository.triageBucket(in: context)
        item.locationChangedAt = .now
        if playlist.role == .oneTruePlaylist,
           !item.suppressedOTPMusicPlaylistIDs.contains(playlist.musicPlaylistID) {
            item.suppressedOTPMusicPlaylistIDs.append(playlist.musicPlaylistID)
        }
        item.playlistID = bucket.id
        item.musicPlaylistEntryID = nil
        EvictionEngine.evict(item, playlist: playlist, reason: reason, source: source, message: message, context: context)
        if !preserveForMerge { try TrackRetentionPolicy.deleteIfUnowned(item, in: context) }
    }

    /// A source's link timestamp is durable intent, so retrying an import can
    /// revive old retirements but cannot undo decisions made after linking.
    static func reconcileIntake(
        _ item: PlaylistItemRecord,
        owner: PlaylistRecord,
        sourcePlaylist: PlaylistRecord,
        entryID: String?,
        at date: Date,
        in context: ModelContext
    ) throws {
        if sourcePlaylist.role == .triageSource {
            item.addSourceMusicPlaylistID(sourcePlaylist.musicPlaylistID)
            if item.playlistID == owner.id,
               let retiredAt = item.evictedAt,
               let linkedAt = sourcePlaylist.triageLinkedAt,
               retiredAt < linkedAt {
                try moveToTriage(item, explicitKeep: false, source: .sync, at: date, in: context)
            }
        } else if sourcePlaylist.role == .oneTruePlaylist,
                  item.playlistID != owner.id, item.evictedAt == nil,
                  !item.suppressedOTPMusicPlaylistIDs.contains(sourcePlaylist.musicPlaylistID) {
            moveToOTP(item, playlist: owner, entryID: entryID, source: .sync, at: date, in: context)
        }
        if item.playlistID == owner.id {
            item.musicPlaylistEntryID = owner.isTriageBucket ? nil : entryID
        }
    }
}
