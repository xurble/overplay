import Foundation
import SwiftData

@Model
final class SettingsRecord {
    var id: UUID = UUID()
    var evictAfterSkips: Int = 3
    var skipThresholdPercentage: Double = 50
    var minimumSkipListeningSeconds: Double = 10
    var playthroughThresholdPercentage: Double = 90
    var playthroughResetsSkipCount: Bool = true
    var protectKeptTracks: Bool = false
    var syncOnForeground: Bool = true
    var foregroundSyncStalenessSeconds: Double = 3600
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        evictAfterSkips: Int = 3,
        skipThresholdPercentage: Double = 50,
        minimumSkipListeningSeconds: Double = 10,
        playthroughThresholdPercentage: Double = 90,
        playthroughResetsSkipCount: Bool = true,
        protectKeptTracks: Bool = false,
        syncOnForeground: Bool = true,
        foregroundSyncStalenessSeconds: Double = 3600,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.evictAfterSkips = evictAfterSkips
        self.skipThresholdPercentage = skipThresholdPercentage
        self.minimumSkipListeningSeconds = minimumSkipListeningSeconds
        self.playthroughThresholdPercentage = playthroughThresholdPercentage
        self.playthroughResetsSkipCount = playthroughResetsSkipCount
        self.protectKeptTracks = protectKeptTracks
        self.syncOnForeground = syncOnForeground
        self.foregroundSyncStalenessSeconds = foregroundSyncStalenessSeconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
