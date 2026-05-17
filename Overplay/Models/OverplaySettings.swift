import Foundation
import SwiftData

@Model
final class OverplaySettings {
    var id: UUID = UUID()
    var selectedPlaylistID: String?
    var selectedPlaylistName: String?
    var evictAfterSkips: Int = 3
    var skipThresholdPercentage: Double = 50
    var minimumSkipListeningSeconds: Double = 10
    var playthroughThresholdPercentage: Double = 90
    var playthroughResetsSkipCount: Bool = true
    var protectKeptTracks: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        selectedPlaylistID: String? = nil,
        selectedPlaylistName: String? = nil,
        evictAfterSkips: Int = 3,
        skipThresholdPercentage: Double = 50,
        minimumSkipListeningSeconds: Double = 10,
        playthroughThresholdPercentage: Double = 90,
        playthroughResetsSkipCount: Bool = true,
        protectKeptTracks: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.selectedPlaylistID = selectedPlaylistID
        self.selectedPlaylistName = selectedPlaylistName
        self.evictAfterSkips = evictAfterSkips
        self.skipThresholdPercentage = skipThresholdPercentage
        self.minimumSkipListeningSeconds = minimumSkipListeningSeconds
        self.playthroughThresholdPercentage = playthroughThresholdPercentage
        self.playthroughResetsSkipCount = playthroughResetsSkipCount
        self.protectKeptTracks = protectKeptTracks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
