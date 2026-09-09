import Foundation
import SwiftData

@Model
final class PlaylistItemRecord {
    var id: UUID = UUID()
    var playlistID: UUID = UUID()
    var trackID: UUID = UUID()
    var musicPlaylistEntryID: String?
    /// Which contributing Apple Music playlists put this track in the triage
    /// bucket. Deliberately allowed to be empty: unlinking a contributor
    /// leaves its rows in the bucket unattributed, and a track added straight
    /// to the bucket never had a contributor at all. Empty means "no known
    /// source", which is a normal state and not an error.
    var sourceMusicPlaylistIDs: [String] = []
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
}
