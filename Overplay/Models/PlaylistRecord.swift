import Foundation
import SwiftData

@Model
final class PlaylistRecord {
    /// Reserved `musicPlaylistID` for the triage bucket. The bucket has no
    /// Apple Music playlist, but the playback stack keys identity, mode and
    /// order state on this string, so it needs a stable value that can never
    /// collide with a real Apple Music playlist identifier.
    nonisolated static let triageBucketMusicPlaylistID = "overplay.triage-bucket"
    nonisolated static let triageBucketName = "Triage"

    var id: UUID = UUID()
    var musicPlaylistID: String = ""
    var name: String = ""
    var sourceRawValue: String = PlaylistSource.appleMusic.rawValue
    var roleRawValue: String = PlaylistRole.triageSource.rawValue
    var writePolicyRawValue: String = PlaylistWritePolicy.managed.rawValue
    var isActive: Bool = true
    var lastSyncedAt: Date?
    var lastSyncError: String?
    /// Apple Music's reported modification date at the last successful
    /// sync. Lets an automatic cycle skip refetching an unchanged playlist.
    var remoteLastModifiedAt: Date?
    /// Older track-only syncs need one full entry fetch even if unchanged.
    var hasSyncedPlaylistEntries: Bool = false
    /// Explicit link intent, distinct from ordinary refresh timestamps. A later
    /// retirement must survive retries of this playlist's original import.
    var triageLinkedAt: Date?
    /// A deletion made after this source was linked beats its still-pending
    /// import (initial or an already-running refresh). Scoped to this link, and discarded on unlink/re-link;
    /// these are not retired items or permanent per-song tombstones.
    var triageExcludedTrackIDs: [String] = []
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var source: PlaylistSource {
        get { PlaylistSource(rawValue: sourceRawValue) ?? .appleMusic }
        set { sourceRawValue = newValue.rawValue }
    }

    var role: PlaylistRole {
        get { PlaylistRole(rawValue: roleRawValue) ?? .triageSource }
        set { roleRawValue = newValue.rawValue }
    }

    /// True while this record still carries the pre-bucket `"triage"` raw
    /// value, so the migration can find it by stored state rather than by a
    /// local flag a reinstall could lose.
    var needsTriageBucketMigration: Bool {
        roleRawValue == PlaylistRole.legacyTriageRawValue
    }

    var isTriageBucket: Bool {
        role == .triageBucket
    }

    /// The bucket has no Apple Music playlist behind it, so it is never
    /// fetched or synced directly — its contents arrive from contributing
    /// sources instead.
    var hasRemoteSource: Bool {
        role != .triageBucket
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
        source: PlaylistSource = .appleMusic,
        role: PlaylistRole = .triageSource,
        writePolicy: PlaylistWritePolicy = .managed,
        isActive: Bool = true,
        lastSyncedAt: Date? = nil,
        lastSyncError: String? = nil,
        remoteLastModifiedAt: Date? = nil,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.musicPlaylistID = musicPlaylistID
        self.name = name
        self.sourceRawValue = source.rawValue
        self.roleRawValue = role.rawValue
        self.writePolicyRawValue = writePolicy.rawValue
        self.isActive = isActive
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncError = lastSyncError
        self.remoteLastModifiedAt = remoteLastModifiedAt
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
