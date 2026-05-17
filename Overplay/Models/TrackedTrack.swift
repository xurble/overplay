import Foundation
import SwiftData

@Model
final class TrackedTrack {
    var id: String = ""
    var catalogID: String?
    var libraryID: String?
    var playlistEntryID: String?
    var playlistID: String?
    var title: String = ""
    var artistName: String = ""
    var albumTitle: String?
    var artworkURLTemplate: String?
    var durationSeconds: Double?
    var skipCount: Int = 0
    var playthroughCount: Int = 0
    var lastPlayedAt: Date?
    var lastSkippedAt: Date?
    var evictedAt: Date?
    var evictionReason: String?
    var protected: Bool = false
    var lastSeenInPlaylistAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: String,
        catalogID: String? = nil,
        libraryID: String? = nil,
        playlistEntryID: String? = nil,
        playlistID: String? = nil,
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURLTemplate: String? = nil,
        durationSeconds: Double? = nil,
        skipCount: Int = 0,
        playthroughCount: Int = 0,
        lastPlayedAt: Date? = nil,
        lastSkippedAt: Date? = nil,
        evictedAt: Date? = nil,
        evictionReason: String? = nil,
        protected: Bool = false,
        lastSeenInPlaylistAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.catalogID = catalogID
        self.libraryID = libraryID
        self.playlistEntryID = playlistEntryID
        self.playlistID = playlistID
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURLTemplate = artworkURLTemplate
        self.durationSeconds = durationSeconds
        self.skipCount = skipCount
        self.playthroughCount = playthroughCount
        self.lastPlayedAt = lastPlayedAt
        self.lastSkippedAt = lastSkippedAt
        self.evictedAt = evictedAt
        self.evictionReason = evictionReason
        self.protected = protected
        self.lastSeenInPlaylistAt = lastSeenInPlaylistAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isEvicted: Bool {
        evictedAt != nil
    }
}
