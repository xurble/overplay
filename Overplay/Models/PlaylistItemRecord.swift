import Foundation
import SwiftData

@Model
final class PlaylistItemRecord {
    var id: UUID = UUID()
    var playlistID: UUID = UUID()
    var trackID: UUID = UUID()
    var musicPlaylistEntryID: String?
    var skipCount: Int = 0
    var playthroughCount: Int = 0
    var lastPlayedAt: Date?
    var lastSkippedAt: Date?
    var lastSeenInPlaylistAt: Date?
    var removedFromRemoteAt: Date?
    var evictedAt: Date?
    var evictionReason: EvictionReason?
    var evictionSource: EvictionSource?
    var protected: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        playlistID: UUID,
        trackID: UUID,
        musicPlaylistEntryID: String? = nil,
        skipCount: Int = 0,
        playthroughCount: Int = 0,
        lastPlayedAt: Date? = nil,
        lastSkippedAt: Date? = nil,
        lastSeenInPlaylistAt: Date? = nil,
        removedFromRemoteAt: Date? = nil,
        evictedAt: Date? = nil,
        evictionReason: EvictionReason? = nil,
        evictionSource: EvictionSource? = nil,
        protected: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.playlistID = playlistID
        self.trackID = trackID
        self.musicPlaylistEntryID = musicPlaylistEntryID
        self.skipCount = skipCount
        self.playthroughCount = playthroughCount
        self.lastPlayedAt = lastPlayedAt
        self.lastSkippedAt = lastSkippedAt
        self.lastSeenInPlaylistAt = lastSeenInPlaylistAt
        self.removedFromRemoteAt = removedFromRemoteAt
        self.evictedAt = evictedAt
        self.evictionReason = evictionReason
        self.evictionSource = evictionSource
        self.protected = protected
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isPlayable: Bool {
        evictedAt == nil && removedFromRemoteAt == nil
    }
}
