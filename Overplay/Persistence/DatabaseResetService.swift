import Foundation
import SwiftData

enum DatabaseResetService {
    @MainActor
    @discardableResult
    static func nukeDatabase(in context: ModelContext) throws -> OverplaySettings {
        try deleteAllRecords(in: context)
        try context.save()

        let settings = OverplaySettings()
        context.insert(settings)
        try context.save()
        return settings
    }

    @MainActor
    private static func deleteAllRecords(in context: ModelContext) throws {
        try context.delete(model: HistoryEvent.self)
        try context.delete(model: PlaylistItemRecord.self)
        try context.delete(model: TrackRecord.self)
        try context.delete(model: PlaylistRecord.self)
        try context.delete(model: SpotifyCredentialsRecord.self)
        try context.delete(model: OverplaySettings.self)
    }
}
