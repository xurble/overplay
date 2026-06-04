import Foundation
import SwiftData

@Model
final class PlaylistRecord {
    var id: UUID = UUID()
    var musicPlaylistID: String = ""
    var name: String = ""
    var roleRawValue: String = PlaylistRole.triage.rawValue
    var writePolicyRawValue: String = PlaylistWritePolicy.managed.rawValue
    var isActive: Bool = true
    var lastSyncedAt: Date?
    var lastSyncError: String?
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var role: PlaylistRole {
        get { PlaylistRole(rawValue: roleRawValue) ?? .triage }
        set { roleRawValue = newValue.rawValue }
    }

    var writePolicy: PlaylistWritePolicy {
        get { PlaylistWritePolicy(rawValue: writePolicyRawValue) ?? .managed }
        set { writePolicyRawValue = newValue.rawValue }
    }

    var allowsRemoteWrites: Bool {
        writePolicy == .managed
    }

    init(
        id: UUID = UUID(),
        musicPlaylistID: String,
        name: String,
        role: PlaylistRole = .triage,
        writePolicy: PlaylistWritePolicy = .managed,
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
        self.roleRawValue = role.rawValue
        self.writePolicyRawValue = writePolicy.rawValue
        self.isActive = isActive
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncError = lastSyncError
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
