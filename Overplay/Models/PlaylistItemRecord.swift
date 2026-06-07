import Foundation
import SwiftData

@Model
final class PlaylistItemRecord {
    var id: UUID = UUID()
    var playlistID: UUID = UUID()
    var trackID: UUID = UUID()
    var musicPlaylistEntryID: String?
    var sortOrder: Int = 0
    var skipCount: Int = 0
    var playthroughCount: Int = 0
    var lastPlayedAt: Date?
    var lastSkippedAt: Date?
    var lastSeenInPlaylistAt: Date?
    var evictedAt: Date?
    var evictionReasonRawValue: String?
    var evictionSourceRawValue: String?
    var protected: Bool = false
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
        sortOrder: Int = 0,
        skipCount: Int = 0,
        playthroughCount: Int = 0,
        lastPlayedAt: Date? = nil,
        lastSkippedAt: Date? = nil,
        lastSeenInPlaylistAt: Date? = nil,
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
        self.sortOrder = sortOrder
        self.skipCount = skipCount
        self.playthroughCount = playthroughCount
        self.lastPlayedAt = lastPlayedAt
        self.lastSkippedAt = lastSkippedAt
        self.lastSeenInPlaylistAt = lastSeenInPlaylistAt
        self.evictedAt = evictedAt
        self.evictionReasonRawValue = evictionReason?.rawValue
        self.evictionSourceRawValue = evictionSource?.rawValue
        self.protected = protected
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isPlayable: Bool {
        evictedAt == nil
    }
}
