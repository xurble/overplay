import Foundation
import SwiftData

@Model
final class LibrarySettingsV2 {
    var id: UUID = UUID()
    var completedRebuildID: UUID?
    var selectedPlaylistID: String?
    var selectedPlaylistName: String?
    var skipThresholdPercentage: Double = 50
    var minimumSkipListeningSeconds: Double = 10
    var playthroughThresholdPercentage: Double = 90
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// A Mac's setup asked for a managed One True Playlist that only an
    /// iPhone or iPad can make (`SETUP-002`); the first one to open makes it.
    var pendingOneTruePlaylistRequestedAt: Date?
    /// The playlist to copy into it; nil for an empty one.
    var pendingOneTruePlaylistSourceID: String?
    var pendingOneTruePlaylistSourceName: String?
    /// The local One True Playlist the Mac made for the request (its
    /// placeholder `musicPlaylistID`). An iPhone or iPad makes the Apple Music
    /// playlist from that record's songs, and waits until iCloud has
    /// delivered it. Nil for a request with nothing made locally.
    var pendingOneTruePlaylistLocalID: String?

    init(
        id: UUID = UUID(),
        selectedPlaylistID: String? = nil,
        selectedPlaylistName: String? = nil,
        skipThresholdPercentage: Double = 50,
        minimumSkipListeningSeconds: Double = 10,
        playthroughThresholdPercentage: Double = 90,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.selectedPlaylistID = selectedPlaylistID
        self.selectedPlaylistName = selectedPlaylistName
        self.skipThresholdPercentage = skipThresholdPercentage
        self.minimumSkipListeningSeconds = minimumSkipListeningSeconds
        self.playthroughThresholdPercentage = playthroughThresholdPercentage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// Source-level name shared by all playback surfaces; storage identity is V2.
typealias OverplaySettings = LibrarySettingsV2
