import Foundation
import SwiftData

@Model
final class PlaylistRecord {
    var id: UUID = UUID()
    var musicPlaylistID: String = ""
    var name: String = ""
    var role: PlaylistRole = PlaylistRole.triage
    var isActive: Bool = true
    var lastSyncedAt: Date?
    var lastSyncError: String?
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        musicPlaylistID: String,
        name: String,
        role: PlaylistRole = .triage,
        isActive: Bool = true,
        lastSyncedAt: Date? = nil,
        lastSyncError: String? = nil,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.musicPlaylistID = musicPlaylistID
        self.name = name
        self.role = role
        self.isActive = isActive
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncError = lastSyncError
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
