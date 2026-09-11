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
            HistoryEvent.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
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
