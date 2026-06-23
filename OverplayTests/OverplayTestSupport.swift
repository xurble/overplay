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
            HistoryEvent.self,
            SpotifyCredentialsRecord.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
