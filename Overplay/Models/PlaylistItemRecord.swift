import Foundation
import SwiftData

@Model
final class PlaylistItemRecord {
    var id: UUID = UUID()
    var playlistID: UUID = UUID()
    var trackID: UUID = UUID()
    var musicPlaylistEntryID: String?
    /// All linked playlists that contributed this track, independent of location.
    var sourceMusicPlaylistIDs: [String] = []
    var isExplicitlyKept: Bool = false
    var hasRecordedActivity: Bool = false
    var pendingRetentionCleanup: Bool = false
    /// Location intent is separate from metadata/stat timestamps, which sync
    /// can update without a user choosing a different collection.
    var locationChangedAt: Date?
    /// Remote OTP memberships superseded by local retirement or movement.
    /// Keep these until a full snapshot proves absence or explicit promotion wins.
    var suppressedOTPMusicPlaylistIDs: [String] = []
    /// Stored default identifies historical rows; new initializers opt out of
    /// the one-time legacy 0/0 cleanup, including after reinstall/CloudKit delivery.
    var ownershipVersion: Int = 0
    var sortOrder: Int = 0
    var skipCount: Int = 0
    var playthroughCount: Int = 0
    var lastPlayedAt: Date?
    var lastSkippedAt: Date?
    var lastSeenInPlaylistAt: Date?
    var evictedAt: Date?
    var evictionReasonRawValue: String?
    var evictionSourceRawValue: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var evictionReason: EvictionReason? {
        get { evictionReasonRawValue.flatMap(EvictionReason.init(rawValue:)) }
        set { evictionReasonRawValue = newValue?.rawValue }
    }

    var evictionSource: EvictionSource? {
        get { evictionSourceRawValue.flatMap(EvictionSource.init(rawValue:)) }
        set { evictionSourceRawValue = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(),
        playlistID: UUID,
        trackID: UUID,
        musicPlaylistEntryID: String? = nil,
        sourceMusicPlaylistIDs: [String] = [],
        isExplicitlyKept: Bool = false,
        hasRecordedActivity: Bool = false,
        suppressedOTPMusicPlaylistIDs: [String] = [],
        ownershipVersion: Int = 1,
        sortOrder: Int = 0,
        skipCount: Int = 0,
        playthroughCount: Int = 0,
        lastPlayedAt: Date? = nil,
        lastSkippedAt: Date? = nil,
        lastSeenInPlaylistAt: Date? = nil,
        evictedAt: Date? = nil,
        evictionReason: EvictionReason? = nil,
        evictionSource: EvictionSource? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.playlistID = playlistID
        self.trackID = trackID
        self.musicPlaylistEntryID = musicPlaylistEntryID
        self.sourceMusicPlaylistIDs = sourceMusicPlaylistIDs
        self.isExplicitlyKept = isExplicitlyKept
        self.hasRecordedActivity = hasRecordedActivity
        self.suppressedOTPMusicPlaylistIDs = suppressedOTPMusicPlaylistIDs
        self.ownershipVersion = ownershipVersion
        self.sortOrder = sortOrder
        self.skipCount = skipCount
        self.playthroughCount = playthroughCount
        self.lastPlayedAt = lastPlayedAt
        self.lastSkippedAt = lastSkippedAt
        self.lastSeenInPlaylistAt = lastSeenInPlaylistAt
        self.evictedAt = evictedAt
        self.evictionReasonRawValue = evictionReason?.rawValue
        self.evictionSourceRawValue = evictionSource?.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isPlayable: Bool {
        evictedAt == nil
    }

    var hasListeningHistory: Bool {
        hasRecordedActivity || skipCount != 0 || playthroughCount != 0
            || lastPlayedAt != nil || lastSkippedAt != nil
    }

    /// Records a contributing playlist without duplicating it, preserving
    /// insertion order so the first contributor stays the primary one shown.
    /// Returns whether anything changed.
    @discardableResult
    func addSourceMusicPlaylistID(_ musicPlaylistID: String) -> Bool {
        guard !sourceMusicPlaylistIDs.contains(musicPlaylistID) else { return false }
        sourceMusicPlaylistIDs.append(musicPlaylistID)
        return true
    }

    /// Drops a contributing playlist, which is what leaves a row unattributed
    /// when its only contributor is unlinked. Returns whether anything
    /// changed.
    @discardableResult
    func removeSourceMusicPlaylistID(_ musicPlaylistID: String) -> Bool {
        guard sourceMusicPlaylistIDs.contains(musicPlaylistID) else { return false }
        sourceMusicPlaylistIDs.removeAll { $0 == musicPlaylistID }
        return true
    }

    /// Carries provenance forward when MusicKit replaces a library playlist
    /// identifier, collapsing duplicates if the new identifier was already
    /// recorded by a previous sync.
    @discardableResult
    func replaceSourceMusicPlaylistID(from oldID: String, to newID: String) -> Bool {
        guard oldID != newID, sourceMusicPlaylistIDs.contains(oldID) else { return false }

        var replacedIDs: [String] = []
        for sourceID in sourceMusicPlaylistIDs {
            let replacement = sourceID == oldID ? newID : sourceID
            if !replacedIDs.contains(replacement) {
                replacedIDs.append(replacement)
            }
        }
        sourceMusicPlaylistIDs = replacedIDs
        return true
    }
}
