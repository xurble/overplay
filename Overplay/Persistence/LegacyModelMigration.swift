import Foundation
import SwiftData

enum LegacyModelMigration {
    @MainActor
    static func migrate(in context: ModelContext) throws {
        let settings = try StartupProfiler.measure("Legacy migration fetch settings") {
            try existingSettings(in: context)
        }
        let containsLegacyTracks: Bool = try StartupProfiler.measure("Legacy migration detect legacy tracks") {
            try hasLegacyTracks(in: context)
        }
        let containsNewPlaylists: Bool = try StartupProfiler.measure("Legacy migration detect new playlists") {
            try hasNewPlaylists(in: context)
        }
        let shouldReset = containsLegacyTracks || (settings?.selectedPlaylistID != nil && !containsNewPlaylists)

        guard shouldReset else {
            StartupProfiler.mark("Legacy migration skipped: no legacy data")
            return
        }

        StartupProfiler.mark("Legacy data found; resetting persisted store")
        try StartupProfiler.measure("Legacy data reset") {
            try resetStore(in: context)
        }
    }

    @MainActor
    private static func existingSettings(in context: ModelContext) throws -> OverplaySettings? {
        var descriptor = FetchDescriptor<OverplaySettings>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @MainActor
    private static func hasLegacyTracks(in context: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<TrackedTrack>()
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    @MainActor
    private static func hasNewPlaylists(in context: ModelContext) throws -> Bool {
        var descriptor = FetchDescriptor<PlaylistRecord>()
        descriptor.fetchLimit = 1
        return try !context.fetch(descriptor).isEmpty
    }

    @MainActor
    private static func resetStore(in context: ModelContext) throws {
        try context.delete(model: PlaybackEvent.self)
        try context.delete(model: HistoryEvent.self)
        try context.delete(model: PlaylistItemRecord.self)
        try context.delete(model: TrackRecord.self)
        try context.delete(model: PlaylistRecord.self)
        try context.delete(model: SettingsRecord.self)
        try context.delete(model: TrackedTrack.self)
        try context.delete(model: OverplaySettings.self)
        try context.save()
    }
}
