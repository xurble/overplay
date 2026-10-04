import Foundation
import SwiftData

enum DatabaseResetService {
    @MainActor
    @discardableResult
    static func nukeDatabase(in context: ModelContext, defaults: UserDefaults = .standard) throws -> OverplaySettings {
        try deleteAllRecords(in: context)
        try context.save()

        let settings = OverplaySettings()
        context.insert(settings)
        context.insert(PlaylistRecord(musicPlaylistID: PlaylistRecord.triageBucketMusicPlaylistID,
            name: PlaylistRecord.triageBucketName, role: .triageBucket, writePolicy: .incomingOnly))
        try context.save()
        LibraryRestorationService.recordLocalConfiguration(settings, defaults: defaults)
        return settings
    }

    @MainActor
    private static func deleteAllRecords(in context: ModelContext) throws {
        try context.delete(model: ApplePlayCountRecord.self)
        try context.delete(model: ListenEvent.self)
        try context.delete(model: HistoryEvent.self)
        try context.delete(model: PlaylistItemRecord.self)
        try context.delete(model: TrackRecord.self)
        try context.delete(model: PlaylistRecord.self)
        try context.delete(model: OverplaySettings.self)
    }
}
