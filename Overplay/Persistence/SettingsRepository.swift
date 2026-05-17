import Foundation
import SwiftData

enum SettingsRepository {
    @discardableResult
    static func settings(in context: ModelContext) throws -> OverplaySettings {
        var descriptor = FetchDescriptor<OverplaySettings>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1

        if let settings = try context.fetch(descriptor).first {
            return settings
        }

        let settings = OverplaySettings()
        context.insert(settings)
        try context.save()
        return settings
    }

    static func selectPlaylist(_ playlist: AppleMusicPlaylist, in context: ModelContext) throws {
        let settings = try settings(in: context)
        try PlaylistRepository.setOneTruePlaylist(playlist, in: context)
        settings.selectedPlaylistID = playlist.id
        settings.selectedPlaylistName = playlist.name
        settings.updatedAt = .now
        try context.save()
    }

    static func save(_ settings: OverplaySettings, in context: ModelContext) throws {
        settings.evictAfterSkips = min(max(settings.evictAfterSkips, 1), 20)
        settings.skipThresholdPercentage = min(max(settings.skipThresholdPercentage, 1), 99)
        settings.minimumSkipListeningSeconds = max(settings.minimumSkipListeningSeconds, 0)
        settings.playthroughThresholdPercentage = min(max(settings.playthroughThresholdPercentage, 1), 100)
        settings.updatedAt = .now
        try context.save()
    }
}
