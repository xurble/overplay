import Foundation
import SwiftData
import Testing
@testable import Overplay

@MainActor
enum OverplayTestSupport {
    static func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            OverplaySettings.self,
            PlaylistRecord.self,
            TrackRecord.self,
            PlaylistItemRecord.self,
            ApplePlayCountRecord.self,
            HistoryEvent.self,
            ListenEvent.self,
            RecentCollectionRecord.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// The store's settings row, made as setup makes it when there is none:
    /// the app's accessor only reads.
    static func seedSettings(in context: ModelContext) throws -> OverplaySettings {
        if let existing = try context.fetch(FetchDescriptor<OverplaySettings>()).first { return existing }
        let settings = OverplaySettings()
        context.insert(settings)
        try context.save()
        return settings
    }
}

/// A disposable domain for controller-owned playback restoration state.
struct PlaybackTestDefaults {
    let suiteName = "OverplayTests.Playback.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
